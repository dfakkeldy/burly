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
#      simulator pair BY NAME via `xcrun simctl list devices --json`.
#      Never creates, clones, or boots any other device -- fails loudly
#      if either named device is missing.
#   2. Boots the named pair.
#   3. Builds the BurlyPhone and BurlyWatch app targets.
#   4. Runs the BurlyPhoneUITests XCUITest suite via `xcodebuild test`.
#   5. Exports screenshots/attachments from the resulting .xcresult into
#      Scripts/output/screenshots/ for digest reports.
#
# RAM guardrails (16 GB build Mac -- non-negotiable):
#   - A global, mkdir-based lock ($LOCK_DIR) serializes this script
#     against any other Burly xcodebuild/simctl work on the machine.
#     Acquired up front (retried every 30s while held) and released via
#     a trap on EXIT/INT/TERM so it is never left dangling.
#   - Every xcodebuild build/test invocation passes
#     -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1.
#   - All Burly builds share one DerivedData directory ($DERIVED_DATA,
#     passed via -derivedDataPath) so nothing accumulates multiple copies.
#   - On every exit path, pass or fail: `xcrun simctl shutdown all`, and
#     any simulator whose name starts with "Clone of" is deleted.
#   - This script never creates, clones, or boots any simulator other
#     than the named "Burly iPhone" / "Burly Watch S11 46mm" pair.
#
# Usage: Scripts/acceptance-sim.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Burly.xcodeproj"
DERIVED_DATA="$REPO_ROOT/DerivedData"     # shared DerivedData for ALL Burly builds (gitignored)
OUTPUT_DIR="$REPO_ROOT/Scripts/output"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
RESULT_BUNDLE="$OUTPUT_DIR/BurlyPhoneUITests.xcresult"
LOCK_DIR="/Users/dfakkeldy/Developer/health-apps/plan/dispatch/sim.lock"

IPHONE_NAME="Burly iPhone"
WATCH_NAME="Burly Watch S11 46mm"

COMMON_XCODEBUILD_FLAGS=(
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1
)

log() { echo "acceptance-sim: $*" >&2; }

# ---------------------------------------------------------------------------
# Global build lock: only one Burly xcodebuild/simctl session at a time.
# ---------------------------------------------------------------------------
acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    log "waiting for build lock at $LOCK_DIR ..."
    sleep 30
  done
  log "build lock acquired ($LOCK_DIR)"
}

# ---------------------------------------------------------------------------
# Cleanup: runs on every exit path (pass, fail, interrupt). Shuts every
# simulator down, deletes stray "Clone of ..." devices simctl/Xcode may
# create when a destination doesn't line up exactly, and releases the lock.
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  set +e

  xcrun simctl shutdown all >/dev/null 2>&1

  xcrun simctl list devices --json 2>/dev/null \
    | grep -E '"udid"|"name"' \
    | paste -d '\t' - - \
    | grep 'Clone of ' \
    | sed -E 's/.*"udid" : "([^"]+)".*/\1/' \
    | while IFS= read -r clone_udid; do
        [ -n "$clone_udid" ] || continue
        log "deleting stray clone device: $clone_udid"
        xcrun simctl delete "$clone_udid" >/dev/null 2>&1
      done

  rmdir "$LOCK_DIR" 2>/dev/null

  if [ "$exit_code" -eq 0 ]; then
    log "PASS"
  else
    log "FAIL (exit $exit_code)"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

acquire_lock

# ---------------------------------------------------------------------------
# Resolve the named pair. Never falls back to creating a device.
# ---------------------------------------------------------------------------
resolve_udid() {
  local name="$1"
  xcrun simctl list devices --json 2>/dev/null \
    | grep -B 20 "\"name\" : \"${name}\"" \
    | grep '"udid" :' \
    | tail -1 \
    | sed -E 's/.*"udid" : "([^"]+)".*/\1/'
}

IPHONE_UDID="$(resolve_udid "$IPHONE_NAME")"
if [ -z "$IPHONE_UDID" ]; then
  log "FATAL: no simulator named '$IPHONE_NAME' found via 'xcrun simctl list devices --json'."
  log "This script never creates simulators -- create the dedicated pair manually and re-run."
  exit 1
fi

WATCH_UDID="$(resolve_udid "$WATCH_NAME")"
if [ -z "$WATCH_UDID" ]; then
  log "FATAL: no simulator named '$WATCH_NAME' found via 'xcrun simctl list devices --json'."
  log "This script never creates simulators -- create the dedicated pair manually and re-run."
  exit 1
fi

log "resolved '$IPHONE_NAME' -> $IPHONE_UDID"
log "resolved '$WATCH_NAME' -> $WATCH_UDID"

# ---------------------------------------------------------------------------
# Boot the named pair (idempotent: -b boots only if not already booted).
# ---------------------------------------------------------------------------
xcrun simctl bootstatus "$IPHONE_UDID" -b
xcrun simctl bootstatus "$WATCH_UDID" -b

rm -rf "$SCREENSHOTS_DIR" "$RESULT_BUNDLE"
mkdir -p "$SCREENSHOTS_DIR"

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
