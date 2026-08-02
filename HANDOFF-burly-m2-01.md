# Handoff — burly-m2-01 (watch app shell)

## 2026-08-02 — Implementation complete, acceptance evidence captured

Done:
- Watch shell built: `BurlyWatch/ContentView.swift` (root, state switch),
  `WatchHomeViewModel.swift`, `RoutineListView.swift` (§2 list + "Empty
  session"), `WaitingForPhoneView.swift` (§5 fresh install),
  `SessionStartStubView.swift` (nav stub), `StoreUnavailableView.swift`,
  `HomeRoute.swift`, `WatchDemoSeed.swift` (DEBUG-only launch-env seed since
  BurlySync has no real transport yet).
- New `BurlyWatchUITests` Xcode target wired by hand into
  `Burly.xcodeproj/project.pbxproj` via the `xcodeproj` gem (script at
  `/private/tmp/.../scratchpad/add_watch_uitests_target.rb`, not committed —
  one-shot). `BurlyWatch.xcscheme` updated with the new Testable.
  `Scripts/acceptance-sim.sh` extended to build+run BurlyWatchUITests and
  export its screenshots.
- `BurlyKit/BurlyKit`: `swift test` (367 tests) and
  `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` (2
  tests) both green, unchanged by this task's diff.
- Bug found + fixed during acceptance run 1: `WatchDemoSeed` looked up
  catalog exercise "Barbell Back Squat" (doesn't exist; real name is "Back
  Squat") — silently seeded zero routines, so the "routines" scenario
  rendered "Waiting for iPhone" instead and `testSeededRoutinesRenderInList`
  failed on "Leg Day" never appearing. Fixed the name; confirmed via
  `build-for-testing` before rerunning.
- Bug found + fixed during acceptance run 2 (both underlying test suites
  actually passed, 0 failures — see full log): `Scripts/acceptance-sim.sh`
  ran `xcresulttool export attachments` twice into the same
  `$SCREENSHOTS_DIR`; the second call's manifest.json collided with the
  first's and the script exited 1 even though PNGs from both suites landed
  on disk. Fixed by giving each suite its own `screenshots/phone` /
  `screenshots/watch` subdirectory. This fix is committed but **not yet
  re-verified by a live acceptance-sim.sh run** — the dispatcher asked me to
  stop rerunning after the second attempt; visual proof that the watch
  screens themselves work is the 3 PNGs recovered from run 2's on-disk
  artifacts (416x496, correct content, confirmed by eye) plus the
  BurlyWatchUITests xcodebuild log showing "Executed 2 tests, with 0
  failures."

Next:
- Dispatcher (or a fresh session) should run `Scripts/acceptance-sim.sh`
  once clean to confirm the manifest.json fix makes the whole script exit 0
  end-to-end (expected, but unverified live).

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m2-01
git log --oneline -5
Scripts/acceptance-sim.sh   # confirm PASS with the manifest.json fix in place
```
