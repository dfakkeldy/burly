# Burly m2-05 handoff — rest timer watch UI and Always-On branch

## Delivered

- Replaced the m2-03 preliminary rest banner with a wall-clock `TimelineView`
  presentation. It takes the persisted `RestTimerState`, renders its stored
  `endDate`, and does not own a `Timer`, accumulated duration, haptic choice,
  or state transition.
- Active watch UI shows a progress ring, countdown, and 44 x 44 pt `-15` /
  `+15` controls around the Log-set area. The countdown is a confirm-free
  skip target.
- The luminance-reduced branch uses the periodic timeline's system-managed
  low-frequency mode plus `isLuminanceReduced`, showing the remaining time at
  1 Hz without the active ring treatment.
- `SessionViewModel` exposes the persisted `RestTimerState` only for rendering;
  adjustments, skip, tick, screen-wake persistence, and `HapticEvent` playback
  remain routed through the existing `SessionEngine` / `RestTimerEngine` seam.
- Added `LoggingScreenUITests.testRestTimerCountsDownAdjustsAndSkips`, using
  stable leaf identifiers and condition-based waits to cover §3 #2:
  log a set, observe a decreasing countdown, add 15 seconds, then tap the
  countdown to clear it.

## Haptic coverage (§3 #4)

No rest-timer engine logic was changed. `RestTimerEngineTests` already asserts
the complete required `HapticEvent` contract through `HapticLog`: default and
disabled 10-second warning, exactly-once 0 mark, repeat exactly once at +5
seconds when no wake was recorded, suppression for an in-window wake in either
call order, and a suspension gap that emits finish/repeat without a stale
warning. The watch `SessionViewModel.tick()` and `adjustRest(by:)` forward the
engine-returned array directly to `HapticPlaying`.

## Verification

Passed (using an isolated writable Clang module cache because the sandbox
forbids Xcode's default cache location):

```text
cd BurlyKit && CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m2-05-module-cache swift test --disable-sandbox
Test run with 645 tests in 68 suites passed after 3.753 seconds.

cd BurlyKit && BURLY_RUN_MIGRATION_SPIKE=1 CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m2-05-module-cache swift test --disable-sandbox --filter MigrationSpikeTests
Test run with 2 tests in 1 suite passed after 0.104 seconds.
```

Simulator acceptance was attempted twice, the allowed maximum, and could not
run in this sandbox:

```text
Scripts/acceptance-sim.sh
FATAL: could not create lock dir '/Users/dfakkeldy/Developer/health-apps/plan/dispatch/sim.lock': Operation not permitted

BURLY_LOCK_DIR=/private/tmp/burly-m2-05-sim.lock Scripts/acceptance-sim.sh
FATAL: 'xcrun simctl list devices --json' failed -- cannot resolve simulator devices.
```

The second failure also reported that `simctl shutdown all` and device listing
could not reach CoreSimulatorService during cleanup. No third acceptance run
was made. The same unavailable CoreSimulatorService prevented a standalone
Watch target build from reaching source compilation, so the Watch UI compile
and XCUITest remain for the dispatcher environment to verify.

## Files changed

- `BurlyWatch/Session/RestTimerBanner.swift`
- `BurlyWatch/Session/ExercisePageView.swift`
- `BurlyWatch/Session/SessionViewModel.swift`
- `BurlyWatchUITests/LoggingScreenUITests.swift`
- `HANDOFF-burly-m2-05.md`

## Ambiguities / follow-up

- The required 46 mm simulator acceptance is blocked solely by sandbox access
  to the simulator service. Re-run `Scripts/acceptance-sim.sh` in the dispatcher
  environment to compile the Watch target and execute the new UI test.

## 2026-08-02 — post-review defensive fixes, dispatcher-verified green

Done: `RestTimerBanner.swift` two-fix review pass — `remaining(at:)` now calls
`RestTimerState.remaining(at:)` instead of restating its formula; the active
row's spacing (8→6) and ring (72→64) shrink the intrinsic width 176pt→164pt
for 41mm headroom, ±15 44x44 hit targets untouched. `swift test` 645/68,
`MigrationSpikeTests` 2/2, `Scripts/acceptance-sim.sh` on the 46mm pair: PASS
(phone 7/7, watch 16/16, `runs/20260802T103200Z`). Committed, not pushed.
Next: none — task-complete pending dispatcher merge decision.
Resume: n/a.
