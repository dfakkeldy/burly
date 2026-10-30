#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/paired-sync-sim.sh
#
# m4-06 paired-simulator sync acceptance: the real phone and watch apps on
# the PAIRED "Burly iPhone" / "Burly Watch S11 46mm" simulators, talking
# over WatchConnectivity on their on-device stores.
#
#   1. Phone: build a routine (BurlyPhoneUITests/PairedSyncUITests).
#   2. Watch: wait for it, log a set, finish (BurlyWatchUITests/PairedSyncUITests).
#   3. Phone: wait for that session in History.
#
# Both apps' sync logs (subsystem com.burly.lifting) and the tests'
# screenshots land in Scripts/output/paired/<UTC-timestamp>/.
#
# Not part of acceptance-sim.sh: it needs the pair, it leaves data in both
# simulators' stores, and WatchConnectivity between simulators is slower
# and less predictable than the standalone suites. It takes the same
# simulator lock as acceptance-sim.sh, so the two never overlap.
#
# Usage: Scripts/paired-sync-sim.sh
# (Agents on the build Mac run it through the build-slot wrapper.)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/DerivedData"
RUN_DIR="$REPO_ROOT/Scripts/output/paired/$(date -u +%Y%m%dT%H%M%SZ)"
LOCK_DIR="${BURLY_LOCK_DIR:-${TMPDIR:-/tmp}/burly-sim.lock}"
PHONE_NAME="Burly iPhone"
WATCH_NAME="Burly Watch S11 46mm"
ROUTINE="Paired $(date -u +%H%M%S)"

LOCK_OWNED=0
LOG_PIDS=()
cleanup() {
  for pid in "${LOG_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  if [[ $LOCK_OWNED == 1 ]]; then rm -rf "$LOCK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "FATAL: $*" >&2; exit 1; }

# The same lock acceptance-sim.sh takes; wait up to 45 minutes for it.
for _ in $(seq 1 270); do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNED=1
    echo "$$ $(date +%s)" > "$LOCK_DIR/owner"
    break
  fi
  sleep 10
done
[[ $LOCK_OWNED == 1 ]] || fail "simulator lock $LOCK_DIR still held after 45 minutes"

# The pair, by name: the phone and watch must be paired with each other.
read -r PHONE WATCH < <(xcrun simctl list pairs --json | /usr/bin/python3 -c '
import json, sys
phone_name, watch_name = sys.argv[1:]
pairs = [p for p in json.load(sys.stdin)["pairs"].values()
         if p["phone"]["name"] == phone_name and p["watch"]["name"] == watch_name]
if len(pairs) != 1:
    sys.exit(f"expected exactly one {phone_name!r} + {watch_name!r} pair, found {len(pairs)}")
print(pairs[0]["phone"]["udid"], pairs[0]["watch"]["udid"])
' "$PHONE_NAME" "$WATCH_NAME") || fail "could not resolve the simulator pair"
echo "phone $PHONE, watch $WATCH, routine '$ROUTINE'"

mkdir -p "$RUN_DIR"
for udid in "$PHONE" "$WATCH"; do
  xcrun simctl boot "$udid" 2>/dev/null
  xcrun simctl bootstatus "$udid" -b > /dev/null || fail "$udid did not boot"
done

xcrun simctl spawn "$PHONE" log stream --level info \
  --predicate 'subsystem == "com.burly.lifting"' > "$RUN_DIR/phone-sync.log" 2>&1 &
LOG_PIDS+=($!)
xcrun simctl spawn "$WATCH" log stream --level info \
  --predicate 'subsystem == "com.burly.lifting"' > "$RUN_DIR/watch-sync.log" 2>&1 &
LOG_PIDS+=($!)

XCB_FLAGS=(-project "$REPO_ROOT/Burly.xcodeproj" -derivedDataPath "$DERIVED_DATA"
           -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)
export TEST_RUNNER_BURLY_PAIRED_SYNC_UI_TESTS=1
export TEST_RUNNER_BURLY_PAIRED_ROUTINE="$ROUTINE"

phone_dest="platform=iOS Simulator,id=$PHONE"
watch_dest="platform=watchOS Simulator,id=$WATCH"

xcodebuild build-for-testing "${XCB_FLAGS[@]}" -scheme BurlyPhone -destination "$phone_dest" \
  > "$RUN_DIR/build-phone.log" 2>&1 || fail "BurlyPhone build-for-testing failed (see $RUN_DIR/build-phone.log)"
xcodebuild build-for-testing "${XCB_FLAGS[@]}" -scheme BurlyWatch -destination "$watch_dest" \
  > "$RUN_DIR/build-watch.log" 2>&1 || fail "BurlyWatch build-for-testing failed (see $RUN_DIR/build-watch.log)"

# Installed before the phone runs, so its launch push finds the watch app
# installed and transfers the routine straight away.
xcrun simctl install "$WATCH" "$DERIVED_DATA/Build/Products/Debug-watchsimulator/BurlyWatch.app" \
  || fail "could not install BurlyWatch on $WATCH"

step() {
  local name=$1 scheme=$2 dest=$3 test=$4
  echo "=== $name"
  xcodebuild test-without-building "${XCB_FLAGS[@]}" -scheme "$scheme" -destination "$dest" \
    -resultBundlePath "$RUN_DIR/$name.xcresult" -only-testing:"$test" \
    > "$RUN_DIR/$name.log" 2>&1
  local rc=$?
  grep -E "error:|skipped|Executed|\*\* TEST" "$RUN_DIR/$name.log" | tail -5
  mkdir -p "$RUN_DIR/$name"
  xcrun xcresulttool export attachments --path "$RUN_DIR/$name.xcresult" \
    --output-path "$RUN_DIR/$name" > /dev/null 2>&1
  grep -q "Test skipped" "$RUN_DIR/$name.log" && fail "$name was skipped"
  [[ $rc == 0 ]] || fail "$name failed (see $RUN_DIR/$name.log)"
}

step 1-phone-routine BurlyPhone "$phone_dest" BurlyPhoneUITests/PairedSyncUITests/testBuildRoutineForWatch
# The runner terminates each app when its test ends, and a simulator often
# holds a terminated sender's queued transfer until that app runs again.
# Relaunch the side that just sent while the other side's test waits; its
# launch push or outbox retry re-fires on activation anyway.
xcrun simctl launch "$PHONE" com.burly.lifting -burly-skip-welcome > /dev/null
step 2-watch-session BurlyWatch "$watch_dest" BurlyWatchUITests/PairedSyncUITests/testPhoneRoutineArrivesAndSessionGoesBack
xcrun simctl launch "$WATCH" com.burly.lifting.watchkitapp > /dev/null
step 3-phone-history BurlyPhone "$phone_dest" BurlyPhoneUITests/PairedSyncUITests/testWatchSessionReachesHistory

echo "PASS: '$ROUTINE' went phone -> watch, and its session came back. Output: $RUN_DIR"
