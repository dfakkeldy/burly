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

## 2026-08-02 — Review round 1 follow-ups landed, acceptance-sim.sh PASS

Done: all 7 findings from `.scratch/m2-01-review-1.md` (commit `5869997`,
"safe to merge with required follow-ups"), no disagreements.

- **2.1/2.2 (major)** `WatchDemoSeed.requestedStore()` now returns
  `Result<BurlyStore, Error>?` instead of `BurlyStore?`; the `try?` that
  turned a seed failure into "no scenario requested" is gone, so
  `BurlyWatchApp`'s `resolveStore()` uses the scenario's `Result` as-is and
  never falls through to the on-device store. Catalog-name drift
  (`WatchDemoSeed.swift` exercise lookup) now throws
  `SeedError.catalogMissingExercise` instead of returning a sparse store.
  Added `Scenario.brokenSeed`, a scenario that always fails construction, and
  a new UI test `testBrokenSeedScenarioFailsClosedToErrorState` asserting the
  error state (not waiting-for-iPhone) appears.
- **4.1 (major)** `ContentView` re-runs `viewModel.load()` on
  `scenePhase == .active` (`.onChange(of: scenePhase)`), and the `.failed`
  branch passes a Retry closure into `StoreUnavailableView`. No timers/
  polling added.
- **3.1 (minor)** `RootView` resolves the store once in `init` via `@State`,
  not in `body`.
- **3.2 (minor)** `WatchHomeViewModel` is `@MainActor`; `ContentView` and
  `RootView` marked `@MainActor` too (required once the view model's
  properties became actor-isolated) — verified by a real
  `build-for-testing`, not just review.
- **6.1 (minor)** `WaitingForPhoneView`, `SessionStartStubView`,
  `StoreUnavailableView` bodies wrapped in `ScrollView`.
- **6.2 (minor)** Added `accessibilityIdentifier`s (`waitingForPhoneView.*`,
  `routineRow.<name>.*`, `emptySessionRow`, `sessionStartStubView.heading`,
  `storeUnavailableView.*`) and switched `BurlyWatchUITests` to select
  through them. Kept "Waiting for iPhone" as a copy assertion too (wording is
  the §5 contract there, per the review's own example); dropped exact-copy
  assertions for relative-date last-done text and the composed "Starting X"
  sentence, since those wordings aren't the contract — the stub heading
  check uses `.label.contains("Leg Day")` instead of an exact match.
- **6.3 (nit)** `accessibilityHidden(true)` on the three decorative SF
  Symbols.

Verification (all commands run for real, not asserted from memory):
- `cd BurlyKit && swift test` → 367 tests, all passed.
- `cd BurlyKit && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter
  MigrationSpikeTests` → 2 tests, all passed (untouched by this diff).
- `xcodebuild build` / `build-for-testing` for `BurlyWatch` and `BurlyPhone`
  (generic simulator destinations, no device booted) → both succeeded, used
  to catch the `@MainActor` propagation before spending the one sim run.
- `Scripts/acceptance-sim.sh` (one run, owns the global lock) →
  `acceptance-sim: PASS`. `BurlyPhoneUITests`: 1/1 passed. `BurlyWatchUITests`:
  3/3 passed (`testBrokenSeedScenarioFailsClosedToErrorState`,
  `testEmptyStoreShowsWaitingForPhone`, `testSeededRoutinesRenderInList`).
  Results: `Scripts/output/runs/20260802T032454Z/` (via `Scripts/output/latest`).

Next: none outstanding from this review round — ready for the dispatcher to
merge/re-review.

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m2-01
git log --oneline -3
cat Scripts/output/latest/../../runs/20260802T032454Z/screenshots/watch/manifest.json  # or just open Scripts/output/latest
```
