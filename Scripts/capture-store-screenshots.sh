#!/bin/bash
# SPDX-License-Identifier: MIT
# Scripts/capture-store-screenshots.sh
#
# The App Store screenshots in fastlane/screenshots/en-US, captured from
# synthetic data (PhoneDemoSeed / WatchDemoSeed `storeScreenshots`) so anyone
# can reproduce them:
#
#   1. iPhone: BurlyPhoneUITests/StoreScreenshotsUITests on "Burly Screenshots
#      iPhone", an iPhone 17 Pro Max (1320 x 2868, App Store Connect's 6.9"
#      slot) on the newest iOS runtime, in light appearance. Created here when
#      missing; it is the only simulator this script ever creates.
#   2. Apple Watch: BurlyWatchUITests/StoreScreenshotsUITests on "Burly Watch
#      S11 46mm" (416 x 496, the Series 10/11 slot) on the newest watchOS
#      runtime, standalone as in acceptance-sim.sh. On the build Mac it
#      exists; CI creates it first (.github/workflows/store-screenshots.yml).
#
# Both tests skip unless BURLY_STORE_SCREENSHOTS=1 reaches the test runner
# (xcodebuild's TEST_RUNNER_ prefix), so the acceptance gate never runs them.
# Status bars are overridden to 9:41 with full signal and battery where the
# platform allows it. Each attachment is renamed to the name its test gave
# it: NN_device_screen.png, because fastlane deliver orders one device's
# screenshots by file name and tells the devices apart by pixel size. Every
# file is redrawn onto an opaque RGB canvas (App Store Connect rejects an
# alpha channel), then checked for its exact size and `hasAlpha: no`. Only
# when all of them pass do they replace the PNGs in fastlane/screenshots/
# en-US, so a failed run never leaves a half-updated listing.
#
# The build carries the listing's version (BURLY_APP_VERSION, default 1.0.0,
# as the Fastfile's listing lane uses), so Settings never shows the
# project's development version. Raw output (logs, result bundles, every
# attachment) goes to Scripts/output/screenshots/<UTC-timestamp>-<pid>/; the
# newest 5 run directories are kept. Takes the same simulator lock as
# acceptance-sim.sh, and shuts down only the simulators it booted.
#
# Usage: Scripts/capture-store-screenshots.sh
# (Agents on the build Mac run it through the build-slot wrapper.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Burly.xcodeproj"
DERIVED_DATA="$REPO_ROOT/DerivedData"
OUTPUT_DIR="$REPO_ROOT/Scripts/output/screenshots"
RUN_DIR=""
RUNS_TO_KEEP=5
STORE_DIR="$REPO_ROOT/fastlane/screenshots/en-US"
LOCK_DIR="${BURLY_LOCK_DIR:-${TMPDIR:-/tmp}/burly-sim.lock}"

PHONE_NAME="Burly Screenshots iPhone"
PHONE_TYPE_NAME="iPhone 17 Pro Max"
PHONE_SIZE="1320x2868"
WATCH_NAME="Burly Watch S11 46mm"
WATCH_SIZE="416x496"
APP_VERSION="${BURLY_APP_VERSION:-1.0.0}"
BUILD_NUMBER=1

# The store set, in store order. Each name is an attachment name in its
# StoreScreenshotsUITests; any other attachment stays in the run directory.
PHONE_SHOTS=(01_iphone_history 02_iphone_session 03_iphone_progression 04_iphone_volume 05_iphone_routine 06_iphone_settings)
WATCH_SHOTS=(01_watch_routines 02_watch_logging 03_watch_rest 04_watch_summary)

LOCK_OWNED=0
BOOTED=()
OVERRIDDEN=()
REPLACING=0
cleanup() {
  local udid
  if [[ $REPLACING == 1 ]]; then
    put_back_previous_store || log "WARNING: could not restore fastlane/screenshots/en-US from $BACKUP_DIR"
  fi
  for udid in "${OVERRIDDEN[@]:-}"; do
    [[ -n "$udid" ]] && xcrun simctl status_bar "$udid" clear > /dev/null 2>&1
  done
  for udid in "${BOOTED[@]:-}"; do
    [[ -n "$udid" ]] && xcrun simctl shutdown "$udid" > /dev/null 2>&1
  done
  if [[ $LOCK_OWNED == 1 ]]; then
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2> /dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log() { echo "store-screenshots: $*" >&2; }
fail() { echo "store-screenshots: FATAL: $*" >&2; exit 1; }

# acceptance-sim.sh's lock (CI passes its own BURLY_LOCK_DIR); wait up to 45
# minutes for it. A lock 30 minutes old whose owner is dead, or that never got
# an owner file, is reclaimed, by the same rule acceptance-sim.sh uses.
lock_is_stale() {
  local owner_pid="" owner_ts="" since
  [[ -r "$LOCK_DIR/owner" ]] && read -r owner_pid owner_ts < "$LOCK_DIR/owner"
  if [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_ts" =~ ^[0-9]+$ ]]; then
    kill -0 "$owner_pid" 2> /dev/null && return 1
    since=$owner_ts
  else
    since="$(stat -f %m "$LOCK_DIR" 2> /dev/null)" || return 1
  fi
  (( $(date +%s) - since >= 30 * 60 ))
}
for _ in $(seq 1 270); do
  if mkdir_err="$(mkdir "$LOCK_DIR" 2>&1)"; then
    LOCK_OWNED=1
    echo "$$ $(date +%s)" > "$LOCK_DIR/owner"
    break
  fi
  # Only an existing lock directory is worth waiting for; a missing parent,
  # a permission error or a file at that path never clears by itself.
  [[ "$mkdir_err" == *"File exists"* ]] || fail "could not create the simulator lock $LOCK_DIR: $mkdir_err"
  [[ -d "$LOCK_DIR" ]] || fail "the simulator lock path $LOCK_DIR exists but is not a directory"
  if lock_is_stale; then
    log "reclaiming the stale simulator lock $LOCK_DIR"
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2> /dev/null
    continue
  fi
  sleep 10
done
[[ $LOCK_OWNED == 1 ]] || fail "simulator lock $LOCK_DIR still held after 45 minutes"
# After the lock, with the pid, so two runs never share a run directory.
# Then keep only the newest RUNS_TO_KEEP (names sort by their UTC prefix).
RUN_DIR="$OUTPUT_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_DIR"
log "run directory: $RUN_DIR"
OLD_RUNS=()
while IFS= read -r old_run; do
  OLD_RUNS+=("$old_run")
done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
for (( i = 0; i < ${#OLD_RUNS[@]} - RUNS_TO_KEEP; i++ )); do
  log "pruning old run directory: ${OLD_RUNS[$i]}"
  rm -rf "${OLD_RUNS[$i]}"
done

# ---------------------------------------------------------------------------
# Resolve both simulators on the newest runtimes, by exact name. Prints
# "<phone type> <iOS runtime> <phone udid or -> <phone state> <watch udid>
# <watch state>". A phone of the right name but another device type, or a
# name matched twice, is a configuration error, never a guess.
# ---------------------------------------------------------------------------
resolve_devices() {
  local kind
  for kind in runtimes devicetypes devices; do
    xcrun simctl list "$kind" --json > "$RUN_DIR/simctl-$kind.json" || return 1
  done
  /usr/bin/python3 -I - "$RUN_DIR" "$PHONE_NAME" "$PHONE_TYPE_NAME" "$WATCH_NAME" <<'PYEOF'
import json
import os
import re
import sys

run_dir, phone_name, phone_type_name, watch_name = sys.argv[1:5]
runtimes, types, devices = (
    json.load(open(os.path.join(run_dir, f"simctl-{kind}.json")))
    for kind in ("runtimes", "devicetypes", "devices")
)

def version_key(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))

def newest_runtime(platform):
    matches = [
        runtime for runtime in runtimes.get("runtimes", [])
        if runtime.get("isAvailable") is True
        and f".SimRuntime.{platform}-" in runtime.get("identifier", "")
    ]
    if not matches:
        sys.exit(f"no available {platform} simulator runtime")
    return max(matches, key=lambda runtime: version_key(runtime["version"]))["identifier"]

def named(runtime, name):
    return [
        device for device in devices.get("devices", {}).get(runtime, [])
        if device.get("name") == name and device.get("isAvailable") is True
    ]

phone_types = [t for t in types.get("devicetypes", []) if t.get("name") == phone_type_name]
if len(phone_types) != 1:
    sys.exit(f"expected one {phone_type_name!r} device type, found {len(phone_types)}")
phone_type = phone_types[0]["identifier"]

ios_runtime = newest_runtime("iOS")
phones = named(ios_runtime, phone_name)
if len(phones) > 1:
    sys.exit(f"{len(phones)} available {phone_name!r} simulators in {ios_runtime}; refusing to guess")
if phones and phones[0].get("deviceTypeIdentifier") != phone_type:
    sys.exit(f"{phone_name!r} is a {phones[0].get('deviceTypeIdentifier')}, not a {phone_type}; delete or rename it")

watch_runtime = newest_runtime("watchOS")
watches = named(watch_runtime, watch_name)
if len(watches) != 1:
    sys.exit(f"expected one available {watch_name!r} simulator in {watch_runtime}, found {len(watches)}")

phone = phones[0] if phones else {"udid": "-", "state": "-"}
print(phone_type, ios_runtime, phone["udid"], phone["state"], watches[0]["udid"], watches[0]["state"])
PYEOF
}

read -r PHONE_TYPE IOS_RUNTIME PHONE PHONE_STATE WATCH WATCH_STATE < <(resolve_devices) \
  || fail "could not resolve the simulators (see above)"
[[ -n "${WATCH:-}" ]] || fail "could not resolve the simulators (see above)"

if [[ $PHONE == "-" ]]; then
  log "creating '$PHONE_NAME' ($PHONE_TYPE_NAME, $IOS_RUNTIME)"
  PHONE="$(xcrun simctl create "$PHONE_NAME" "$PHONE_TYPE" "$IOS_RUNTIME")" || fail "could not create '$PHONE_NAME'"
  PHONE_STATE="Shutdown"
fi
log "phone '$PHONE_NAME' $PHONE ($PHONE_STATE), watch '$WATCH_NAME' $WATCH ($WATCH_STATE)"

boot() {
  local udid=$1 state=$2
  if [[ $state != "Booted" ]]; then
    BOOTED+=("$udid")
  fi
  xcrun simctl bootstatus "$udid" -b > /dev/null || fail "$udid did not boot"
}
boot "$PHONE" "$PHONE_STATE"
boot "$WATCH" "$WATCH_STATE"

# A booted simulator can take minutes to reach xcodebuild on a fresh runner
# (acceptance-sim.sh measured 82-386 s); poll for it like that script does.
wait_for_destination() {
  local scheme=$1 udid=$2 deadline=$((SECONDS + 15 * 60)) destinations
  while true; do
    destinations="$(xcodebuild -showdestinations -project "$PROJECT" -scheme "$scheme" 2>&1 || true)"
    [[ "$destinations" == *"id:$udid"* ]] && return 0
    if (( SECONDS >= deadline )); then
      printf '%s\n' "$destinations" >&2
      fail "xcodebuild still cannot see $udid for $scheme after 15 minutes"
    fi
    log "waiting for xcodebuild to see $udid for $scheme"
    sleep 15
  done
}
wait_for_destination BurlyPhone "$PHONE"
wait_for_destination BurlyWatch "$WATCH"

# The marketing status bar. iOS takes every field; watchOS may refuse the
# override, which leaves the watch showing the real time.
xcrun simctl status_bar "$PHONE" override --time 9:41 \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState discharging --batteryLevel 100 \
  || fail "could not override the iPhone status bar"
OVERRIDDEN+=("$PHONE")
if xcrun simctl status_bar "$WATCH" override --time 9:41 2> "$RUN_DIR/watch-status-bar.log"; then
  OVERRIDDEN+=("$WATCH")
else
  log "WARNING: the watch refused a status bar override ($(tr '\n' ' ' < "$RUN_DIR/watch-status-bar.log")); its clock shows the real time"
fi
# Light appearance stays set: the phone is this script's own device. The
# watch keeps every setting; its override, if taken, is cleared on exit.
xcrun simctl ui "$PHONE" appearance light || fail "could not set the iPhone to light appearance"

# ---------------------------------------------------------------------------
# Run one screenshot test, export its attachments, and require that it ran
# and passed: a skip (the gate variable never arrived) is a failure here.
# ---------------------------------------------------------------------------
export TEST_RUNNER_BURLY_STORE_SCREENSHOTS=1

run_capture() {
  local name=$1 scheme=$2 destination=$3 test=$4
  local bundle="$RUN_DIR/$name.xcresult" rc=0 summary
  log "running $test"
  xcodebuild test -project "$PROJECT" -scheme "$scheme" -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$bundle" -only-testing:"$test" \
    MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    > "$RUN_DIR/$name.log" 2>&1 || rc=$?
  grep -E "error:|Test Case .*(passed|failed|skipped)|\*\* TEST" "$RUN_DIR/$name.log" | tail -20 >&2

  mkdir -p "$RUN_DIR/$name"
  [[ -d "$bundle" ]] && xcrun xcresulttool export attachments --path "$bundle" \
    --output-path "$RUN_DIR/$name" > /dev/null 2>&1
  if [[ $rc != 0 ]]; then
    tail -60 "$RUN_DIR/$name.log" >&2
    fail "$test failed (exit $rc; see $RUN_DIR/$name.log)"
  fi

  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>&1)" \
    || fail "could not read $bundle: $summary"
  /usr/bin/python3 -I -c '
import json, sys
summary = json.loads(sys.argv[1])
counts = {key: summary.get(key) for key in ("passedTests", "failedTests", "skippedTests")}
if counts != {"passedTests": 1, "failedTests": 0, "skippedTests": 0}:
    sys.exit(f"expected exactly one passed test, got {counts}")
' "$summary" || fail "$test did not run as one passing test (skipped means BURLY_STORE_SCREENSHOTS never reached it)"
}

run_capture phone BurlyPhone "platform=iOS Simulator,id=$PHONE" BurlyPhoneUITests/StoreScreenshotsUITests
run_capture watch BurlyWatch "platform=watchOS Simulator,id=$WATCH" BurlyWatchUITests/StoreScreenshotsUITests

# ---------------------------------------------------------------------------
# Rename into a staging directory. xcresulttool names each export by UUID;
# its manifest's suggestedHumanReadableName is "<attachment name>_<n>_<UUID>.png".
# ---------------------------------------------------------------------------
STAGE_DIR="$RUN_DIR/store"
mkdir -p "$STAGE_DIR"
if ! /usr/bin/python3 -I - "$STAGE_DIR" "$RUN_DIR/phone" "$RUN_DIR/watch" "${PHONE_SHOTS[*]} ${WATCH_SHOTS[*]}" <<'PYEOF'
import json
import os
import re
import shutil
import sys

stage, phone_dir, watch_dir, wanted = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
found = {}
for directory in (phone_dir, watch_dir):
    with open(os.path.join(directory, "manifest.json")) as file:
        manifest = json.load(file)
    for test in manifest:
        for attachment in test.get("attachments", []):
            suggested = attachment.get("suggestedHumanReadableName", "")
            match = re.fullmatch(r"(.+)_\d+_[0-9A-Fa-f-]{36}\.png", suggested)
            name = match.group(1) if match else os.path.splitext(suggested)[0]
            if name in found and name in wanted:
                sys.exit(f"two attachments are named {name!r}")
            found[name] = os.path.join(directory, attachment["exportedFileName"])

missing = [name for name in wanted if name not in found]
if missing:
    sys.exit(f"missing screenshots: {', '.join(missing)} (attachments found: {', '.join(sorted(found))})")
for name in wanted:
    shutil.copyfile(found[name], os.path.join(stage, name + ".png"))
for name in sorted(set(found) - set(wanted)):
    print(f"store-screenshots: not a store screenshot, left in the run directory: {name}", file=sys.stderr)
PYEOF
then
  fail "could not collect the store screenshots (see above)"
fi

# Redraw every file onto an opaque 8-bit RGB canvas in its own RGB color
# space, the way generate-app-icon.swift writes the icon.
if ! swift - "$STAGE_DIR"/*.png <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("cannot make an RGB canvas for \(path)")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flattened = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("cannot encode \(path)")
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("cannot write \(path)")
    }
}
SWIFT
then
  fail "could not flatten the screenshots"
fi

# ---------------------------------------------------------------------------
# Verify every file, then replace the listing's screenshots.
# ---------------------------------------------------------------------------
BAD=0
for shot in "${PHONE_SHOTS[@]}" "${WATCH_SHOTS[@]}"; do
  file="$STAGE_DIR/$shot.png"
  case "$shot" in
    *_iphone_*) expected="$PHONE_SIZE" ;;
    *_watch_*) expected="$WATCH_SIZE" ;;
  esac
  info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file" 2>&1)"
  width="$(awk '/pixelWidth:/ { print $2 }' <<< "$info")"
  height="$(awk '/pixelHeight:/ { print $2 }' <<< "$info")"
  alpha="$(awk '/hasAlpha:/ { print $2 }' <<< "$info")"
  if [[ "${width}x${height}" == "$expected" && "$alpha" == "no" ]]; then
    log "ok $shot.png ${width}x${height} hasAlpha: $alpha"
  else
    log "BAD $shot.png is ${width:-?}x${height:-?} hasAlpha: ${alpha:-?}, expected $expected with no alpha"
    BAD=1
  fi
done
[[ $BAD == 0 ]] || fail "screenshot verification failed; fastlane/screenshots/en-US is unchanged"

# Copy the new set in under temporary names, then drop the old PNGs and
# rename. The previous set is kept in the run directory first, and any
# failure on the way puts it back.
BACKUP_DIR="$RUN_DIR/previous-store"
mkdir -p "$STORE_DIR" "$BACKUP_DIR"
shopt -s nullglob
PREVIOUS=("$STORE_DIR"/*.png)
shopt -u nullglob
if (( ${#PREVIOUS[@]} > 0 )); then
  cp "${PREVIOUS[@]}" "$BACKUP_DIR"/ || fail "could not back up $STORE_DIR; nothing in it was changed"
fi
put_back_previous_store() {
  rm -f "$STORE_DIR"/*.png "$STORE_DIR"/.*.png.new
  (( ${#PREVIOUS[@]} == 0 )) || cp "$BACKUP_DIR"/*.png "$STORE_DIR"/
}
restore_store() {
  REPLACING=0
  put_back_previous_store || fail "$1, and restoring the previous set from $BACKUP_DIR failed too"
  fail "$1; fastlane/screenshots/en-US was restored to its previous set"
}
# From here until the last rename, an interrupt also restores (cleanup).
REPLACING=1
for shot in "${PHONE_SHOTS[@]}" "${WATCH_SHOTS[@]}"; do
  cp "$STAGE_DIR/$shot.png" "$STORE_DIR/.$shot.png.new" || restore_store "could not copy $shot.png"
done
rm -f "$STORE_DIR"/*.png || restore_store "could not remove the previous PNGs"
for shot in "${PHONE_SHOTS[@]}" "${WATCH_SHOTS[@]}"; do
  mv "$STORE_DIR/.$shot.png.new" "$STORE_DIR/$shot.png" || restore_store "could not move $shot.png into place"
done
REPLACING=0
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Store screenshots"
    for shot in "${PHONE_SHOTS[@]}" "${WATCH_SHOTS[@]}"; do echo "- \`$shot.png\`"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi
log "PASS: ${#PHONE_SHOTS[@]} iPhone and ${#WATCH_SHOTS[@]} Apple Watch screenshots in $STORE_DIR (raw output: $RUN_DIR)"
