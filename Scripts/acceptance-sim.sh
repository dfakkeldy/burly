#!/bin/bash
# Scripts/acceptance-sim.sh
#
# CI-CANONICAL ACCEPTANCE COMMANDS. Task m0-04 (CI) runs this script
# verbatim as the Burly simulator acceptance gate -- any change to how
# Burly is built/tested for acceptance belongs here, not in a parallel
# script or a CI-only variant.
#
# What this does, in order:
#   1. Resolves the dedicated "Burly iPhone" / "Burly Watch S11 46mm"
#      simulator pair BY NAME via `xcrun simctl list devices --json`,
#      parsed with the macOS-bundled /usr/bin/python3 (a system tool that
#      ships with every Mac, not a project dependency -- not Homebrew
#      python, not a pinned interpreter). The match must be exact-name,
#      isAvailable == true, and scoped to the single newest installed
#      runtime for that platform (newest iOS runtime for the phone,
#      newest watchOS runtime for the watch). More than one available
#      match for a name is treated as a configuration error and fails
#      loudly rather than silently picking one.
#      Never creates, clones, or boots any other device -- fails loudly
#      if either named device is missing or ambiguous.
#   2. Boots the named pair.
#   3. Builds the BurlyPhone and BurlyWatch app targets.
#   4. Runs the BurlyPhoneUITests XCUITest suite via `xcodebuild test`.
#   5. Exports screenshots/attachments from the resulting .xcresult into
#      a fresh Scripts/output/runs/<UTC-timestamp>/ directory (previous
#      runs are never overwritten in place -- each run gets its own
#      directory, so there is no result-bundle path collision), updates
#      the Scripts/output/latest symlink to point at it, and prunes
#      run directories beyond the newest 5.
#
# RAM guardrails (16 GB build Mac -- non-negotiable):
#   - A global, mkdir-based lock ($LOCK_DIR) serializes this script
#     against any other Burly xcodebuild/simctl work on the machine.
#     The lock is NOT installed as a cleanup-trap target until it is
#     actually acquired -- a process still waiting for the lock (a
#     "waiter") never owns it and must never run simulator/lock cleanup
#     if it is interrupted. See acquire_lock()/cleanup() below.
#   - Lock acquisition writes an owner file ("$LOCK_DIR/owner" = "<pid>
#     <unix ts>") so a dead holder's lock can be detected and recovered:
#     if the owner file is older than 30 minutes AND its pid is no
#     longer alive, the lock is treated as stale, is recovered (with a
#     loud log line and `xcrun simctl shutdown all` to clear whatever
#     the dead owner left booted), and re-acquired. Waiting for the lock
#     has a hard 45-minute timeout, after which the script exits
#     non-zero with a FATAL message rather than waiting forever.
#   - Every xcodebuild build/test invocation passes
#     -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1.
#   - All Burly builds share one DerivedData directory ($DERIVED_DATA,
#     passed via -derivedDataPath) so nothing accumulates multiple copies.
#   - On every exit path where THIS process holds the lock (pass, fail,
#     or a cancelled/interrupted run) -- and only then --:
#     `xcrun simctl shutdown all` runs, any simulator whose name starts
#     with "Clone of" is deleted, and the lock is released. If shutdown
#     or clone deletion fails, that is logged loudly AND forces the
#     script's own exit code non-zero, even if the tests themselves
#     passed -- leaving shared simulator state dirty counts as a failed
#     acceptance run.
#   - A cancelled run (SIGINT/SIGTERM) always exits 130/143 respectively,
#     never 0, and never prints PASS -- regardless of what the
#     in-flight command's exit status happened to be.
#   - This script never creates, clones, or boots any simulator other
#     than the named "Burly iPhone" / "Burly Watch S11 46mm" pair.
#
# Usage: Scripts/acceptance-sim.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Burly.xcodeproj"
DERIVED_DATA="$REPO_ROOT/DerivedData"     # shared DerivedData for ALL Burly builds (gitignored)
OUTPUT_DIR="$REPO_ROOT/Scripts/output"
RUNS_DIR="$OUTPUT_DIR/runs"
LATEST_LINK="$OUTPUT_DIR/latest"
LOCK_DIR="${BURLY_LOCK_DIR:-/Users/dfakkeldy/Developer/health-apps/plan/dispatch/sim.lock}"
OWNER_FILE="$LOCK_DIR/owner"

IPHONE_NAME="Burly iPhone"
WATCH_NAME="Burly Watch S11 46mm"

LOCK_TIMEOUT_SECONDS=$((45 * 60))
STALE_LOCK_SECONDS=$((30 * 60))
RUNS_TO_KEEP=5

COMMON_XCODEBUILD_FLAGS=(
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1
)

# Mutable state referenced by traps -- must exist before any trap can fire.
LOCK_OWNED=0
CLEANUP_DONE=0
RUN_DIR=""

log() { echo "acceptance-sim: $*" >&2; }

# ---------------------------------------------------------------------------
# Pre-lock signal safety.
#
# While this process is only WAITING for the lock, it does not own any
# simulator state and must never run the full cleanup (that would tear down
# the active lock holder's simulators/lock out from under it). These handlers
# are installed BEFORE acquire_lock() is called and are replaced by the full
# cleanup trap only after the lock is actually acquired.
# ---------------------------------------------------------------------------
early_signal_exit() {
  local code="$1"
  log "received signal before acquiring the build lock -- exiting without touching simulators or the lock (exit $code)"
  exit "$code"
}
trap 'early_signal_exit 130' INT
trap 'early_signal_exit 143' TERM

# ---------------------------------------------------------------------------
# Cleanup: installed only once the lock is actually held. Runs on every exit
# path (pass, fail, interrupt) for the lock OWNER only.
#
#   - INT/TERM always force exit 130/143, never PASS, never exit 0 --
#     regardless of what $? happened to be from the command in flight.
#   - Natural EXIT (script ran to completion or `set -e` aborted it) uses
#     the real $? so normal pass/fail exit codes are preserved.
#   - `xcrun simctl shutdown all` and stray-clone deletion results are
#     checked explicitly; either failing is logged loudly and forces the
#     final exit code non-zero even if the tests passed, because leaving
#     shared simulator state dirty is itself a failed acceptance run.
#   - The lock (dir + owner file) is only ever removed here if THIS
#     process is the one that acquired it (LOCK_OWNED=1).
# ---------------------------------------------------------------------------
cleanup() {
  local natural_code=$?
  local exit_code="${1:-$natural_code}"

  if [ "$CLEANUP_DONE" -eq 1 ]; then
    exit "$exit_code"
  fi
  CLEANUP_DONE=1

  set +e
  local dirty=0

  if [ "$LOCK_OWNED" -eq 1 ]; then
    if ! xcrun simctl shutdown all >/dev/null 2>&1; then
      log "WARNING: 'xcrun simctl shutdown all' failed during cleanup -- shared simulator state may be dirty"
      dirty=1
    fi

    # The while-loop below runs as the last stage of a pipe, i.e. in its own
    # subshell -- variables it sets are invisible to this shell, and its
    # natural exit status is dominated by `read` hitting EOF (the common,
    # totally fine "zero clones found" case), not by whether a delete
    # actually failed. Use a marker file instead of trusting `$?` off the
    # pipe so a real delete failure is never confused with "nothing to do".
    local clone_fail_marker
    clone_fail_marker="$(mktemp -u -t burly-clone-fail)"
    rm -f "$clone_fail_marker" 2>/dev/null

    xcrun simctl list devices --json 2>/dev/null \
      | grep -E '"udid"|"name"' \
      | paste -d '\t' - - \
      | grep 'Clone of ' \
      | sed -E 's/.*"udid" : "([^"]+)".*/\1/' \
      | while IFS= read -r clone_udid; do
          [ -n "$clone_udid" ] || continue
          log "deleting stray clone device: $clone_udid"
          if ! xcrun simctl delete "$clone_udid" >/dev/null 2>&1; then
            log "WARNING: failed to delete stray clone device $clone_udid"
            touch "$clone_fail_marker"
          fi
        done

    if [ -f "$clone_fail_marker" ]; then
      log "WARNING: one or more stray 'Clone of' devices could not be deleted -- shared simulator state may be dirty"
      dirty=1
      rm -f "$clone_fail_marker"
    fi

    rm -f "$OWNER_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
  fi

  finalize_run_artifacts

  if [ "$dirty" -eq 1 ] && [ "$exit_code" -eq 0 ]; then
    log "forcing failure: cleanup did not leave shared simulator state clean, even though the run itself passed"
    exit_code=1
  fi

  if [ "$exit_code" -eq 0 ]; then
    log "PASS"
  else
    log "FAIL (exit $exit_code)"
  fi
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Artifact history bookkeeping: point Scripts/output/latest at this run's
# directory (if one was created) and prune run directories beyond the
# newest RUNS_TO_KEEP. Runs unconditionally from cleanup() so it happens on
# every completed/failed/cancelled-after-lock-acquired run, not only green
# ones.
# ---------------------------------------------------------------------------
finalize_run_artifacts() {
  if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    return 0
  fi

  ln -sfn "runs/$(basename "$RUN_DIR")" "$LATEST_LINK"

  [ -d "$RUNS_DIR" ] || return 0

  local -a all_runs=()
  local d
  while IFS= read -r d; do
    all_runs+=("$d")
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  local total=${#all_runs[@]}
  if [ "$total" -le "$RUNS_TO_KEEP" ]; then
    return 0
  fi

  local to_delete=$((total - RUNS_TO_KEEP))
  local i=0
  while [ "$i" -lt "$to_delete" ]; do
    log "pruning old run directory: ${all_runs[$i]}"
    rm -rf "${all_runs[$i]}"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# Global build lock: only one Burly xcodebuild/simctl session at a time.
# ---------------------------------------------------------------------------
reclaim_stale_lock_if_any() {
  [ -f "$OWNER_FILE" ] || return 1

  local owner_pid owner_ts
  read -r owner_pid owner_ts < "$OWNER_FILE" 2>/dev/null || return 1
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$owner_ts" =~ ^[0-9]+$ ]] || return 1

  local now age
  now=$(date +%s)
  age=$((now - owner_ts))
  [ "$age" -ge "$STALE_LOCK_SECONDS" ] || return 1

  if kill -0 "$owner_pid" 2>/dev/null; then
    return 1   # owner process is still alive -- just slow, not stale
  fi

  log "STALE LOCK DETECTED: owner pid $owner_pid is dead and the lock is ${age}s old (>= ${STALE_LOCK_SECONDS}s) -- recovering"
  rm -f "$OWNER_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null
  log "shutting down all simulators to clear residual state left by the dead lock owner"
  xcrun simctl shutdown all >/dev/null 2>&1
  return 0
}

acquire_lock() {
  local start_ts
  start_ts=$(date +%s)

  while true; do
    local mkdir_err
    if mkdir_err="$(mkdir "$LOCK_DIR" 2>&1)"; then
      LOCK_OWNED=1
      printf '%s %s\n' "$$" "$(date +%s)" > "$OWNER_FILE"
      # Only now do we own anything worth protecting -- install the real
      # cleanup trap, replacing the pre-lock signal-only handlers.
      trap cleanup EXIT
      trap 'cleanup 130' INT
      trap 'cleanup 143' TERM
      log "build lock acquired ($LOCK_DIR), owner pid $$"
      return 0
    fi

    if [[ "$mkdir_err" != *"File exists"* ]]; then
      log "FATAL: could not create lock dir '$LOCK_DIR': $mkdir_err"
      exit 1
    fi

    local now
    now=$(date +%s)
    if [ $((now - start_ts)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
      log "FATAL: timed out after $((LOCK_TIMEOUT_SECONDS / 60)) minutes waiting for build lock at $LOCK_DIR"
      exit 1
    fi

    if reclaim_stale_lock_if_any; then
      log "retrying lock acquisition immediately after stale-lock recovery"
      continue
    fi

    log "waiting for build lock at $LOCK_DIR ..."
    # Backgrounded + `wait` rather than a plain foreground `sleep 30`: bash
    # defers running a pending INT/TERM trap until the *entire* enclosing
    # compound command (this while loop) returns when the wait is a plain
    # foreground `sleep` -- so a real Ctrl-C/SIGINT while waiting would
    # never actually interrupt this loop. `wait` on a backgrounded sleep is
    # a shell builtin that returns immediately (>128) the moment a trapped
    # signal arrives, making the wait genuinely interruptible.
    sleep 30 &
    wait "$!"
  done
}

acquire_lock

# ---------------------------------------------------------------------------
# Fresh run directory for this invocation. Created up front (before device
# resolution) so even an early FATAL still leaves a timestamped record and
# an up-to-date `latest` pointer, and so `xcresulttool`/`xcodebuild` always
# write into a directory that has never existed before -- eliminating the
# result-bundle manifest collision that came from reusing one fixed path.
# ---------------------------------------------------------------------------
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RUNS_DIR/$RUN_TS"
SCREENSHOTS_DIR="$RUN_DIR/screenshots"
RESULT_BUNDLE="$RUN_DIR/BurlyPhoneUITests.xcresult"
mkdir -p "$SCREENSHOTS_DIR"
log "run directory: $RUN_DIR"

# ---------------------------------------------------------------------------
# Resolve the named pair by parsing `xcrun simctl list devices --json` with
# the macOS-bundled /usr/bin/python3 (a system tool present on every Mac,
# not a project dependency). Exact name match, isAvailable == true only,
# scoped to the single newest installed runtime for the platform. More than
# one available match is a configuration error and fails loudly rather than
# silently picking one. Never falls back to creating a device.
# ---------------------------------------------------------------------------
DEVICES_JSON_FILE="$(mktemp -t burly-acceptance-devices)"

if ! xcrun simctl list devices --json > "$DEVICES_JSON_FILE" 2>/dev/null; then
  log "FATAL: 'xcrun simctl list devices --json' failed -- cannot resolve simulator devices."
  exit 1
fi

resolve_udid() {
  local name="$1" platform="$2"
  /usr/bin/python3 - "$DEVICES_JSON_FILE" "$name" "$platform" <<'PYEOF'
import json
import sys

path, name, platform = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

devices = data.get("devices", {})
marker = "." + platform + "-"


def version_key(runtime_id):
    tail = runtime_id.rsplit(marker, 1)[-1]
    parts = []
    for chunk in tail.split("-"):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    return tuple(parts)


runtimes = [rid for rid in devices if marker in rid]
if not runtimes:
    print(f"no installed {platform} simulator runtime", file=sys.stderr)
    sys.exit(2)

newest = max(runtimes, key=version_key)

matches = [
    d for d in devices.get(newest, [])
    if d.get("name") == name and d.get("isAvailable") is True
]

if not matches:
    print(f"no available device named '{name}' in newest {platform} runtime {newest}", file=sys.stderr)
    sys.exit(1)

if len(matches) > 1:
    udids = ", ".join(m.get("udid", "?") for m in matches)
    print(
        f"ambiguous: {len(matches)} available devices named '{name}' in runtime {newest}: {udids}",
        file=sys.stderr,
    )
    sys.exit(3)

print(matches[0]["udid"])
PYEOF
}

# Resolver failures must never escape via `set -e` before we get a chance to
# print the device-specific FATAL message -- capture the outcome explicitly.
resolve_device_or_die() {
  local device_name="$1" platform="$2" outvar="$3"
  local udid rc

  if udid="$(resolve_udid "$device_name" "$platform")"; then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -ne 0 ] || [ -z "$udid" ]; then
    case "$rc" in
      2)
        log "FATAL: no $platform simulator runtime is installed on this Mac -- cannot resolve '$device_name'."
        ;;
      3)
        log "FATAL: ambiguous device name '$device_name' -- more than one available $platform simulator matches. Refusing to guess."
        ;;
      *)
        log "FATAL: no available simulator named '$device_name' found via 'xcrun simctl list devices --json' (scoped to the newest $platform runtime)."
        ;;
    esac
    log "This script never creates simulators -- create/fix the dedicated '$device_name' device manually and re-run."
    exit 1
  fi

  printf -v "$outvar" '%s' "$udid"
}

resolve_device_or_die "$IPHONE_NAME" "iOS" IPHONE_UDID
resolve_device_or_die "$WATCH_NAME" "watchOS" WATCH_UDID
rm -f "$DEVICES_JSON_FILE"

log "resolved '$IPHONE_NAME' -> $IPHONE_UDID"
log "resolved '$WATCH_NAME' -> $WATCH_UDID"

# ---------------------------------------------------------------------------
# Boot the named pair (idempotent: -b boots only if not already booted).
# ---------------------------------------------------------------------------
xcrun simctl bootstatus "$IPHONE_UDID" -b
xcrun simctl bootstatus "$WATCH_UDID" -b

# ---------------------------------------------------------------------------
# Build both app targets.
# ---------------------------------------------------------------------------
log "building BurlyPhone on $IPHONE_NAME"
xcodebuild build \
  -project "$PROJECT" \
  -scheme BurlyPhone \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  "${COMMON_XCODEBUILD_FLAGS[@]}"

log "building BurlyWatch on $WATCH_NAME"
xcodebuild build \
  -project "$PROJECT" \
  -scheme BurlyWatch \
  -destination "platform=watchOS Simulator,id=$WATCH_UDID" \
  "${COMMON_XCODEBUILD_FLAGS[@]}"

# ---------------------------------------------------------------------------
# Run the UI test suite.
# ---------------------------------------------------------------------------
log "running BurlyPhoneUITests on $IPHONE_NAME"
xcodebuild test \
  -project "$PROJECT" \
  -scheme BurlyPhone \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:BurlyPhoneUITests \
  "${COMMON_XCODEBUILD_FLAGS[@]}"

# ---------------------------------------------------------------------------
# Export screenshots/attachments for digest reports.
# ---------------------------------------------------------------------------
log "exporting screenshots to $SCREENSHOTS_DIR"
xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$SCREENSHOTS_DIR"

log "screenshots exported:"
find "$SCREENSHOTS_DIR" -type f -print >&2
