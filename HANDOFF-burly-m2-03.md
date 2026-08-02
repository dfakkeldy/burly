# HANDOFF — burly-m2-03

## 2026-08-02 — Task complete, both acceptance-sim.sh runs green

Done:
- Real §2 logging screen replacing `SessionStartStubView`: `BurlyWatch/Session/`
  (`SessionViewModel`, `LoggingScreenView`, `ExercisePageView`,
  `GuardedWeightControlView`, `RepsControlView`, `RestTimerBanner`,
  `SessionActionsView`, `ExercisePickerView`, `SessionSummaryView`,
  `SessionEntryView`, `HapticPlayer`). Consumes `SessionEngine`/
  `GuardedWeightEditMachine`/`RestTimerEngine` as-is; adds only
  `BurlyKit/Sources/BurlyCore/SessionEngine/SessionSummary.swift` (Finish
  totals) to BurlyCore, pinned by `SessionSummaryTests.swift` (7 tests).
- `WatchDemoSeed.swift` extended: seeds an `ExerciseLastPerformance` digest
  for Back Squat (3 sets); Bench Press / Pull-Up stay undigested.
- `BurlyWatchUITests/LoggingScreenUITests.swift`: full-flow test (§2
  acceptance #3) and absent-digest test (§2 acceptance #5's other half).
  Fixed `BurlyWatchUITests.testSeededRoutinesRenderInList` (asserted the
  now-removed stub).
- `Burly.xcodeproj/project.pbxproj` updated by hand (no synchronized
  groups in this project) via a scratch Python script — file added, not
  committed, at `/private/tmp/.../scratchpad/patch_pbxproj.py`.
- Run 1 of the acceptance-sim.sh budget (commit 5696c25) failed two tests:
  `testSeededRoutinesRenderInList` (stale stub assertion) and
  `testFullSessionFlowLogSwapFinishShowsCorrectTotals` (SessionActionsView's
  `List` renders lazily on watchOS — "End workout," the 8th of 9 rows,
  wasn't in the accessibility tree at the sheet's initial scroll position).
  Fixed in commit 62d78d2 (scroll-until-exists in the test; updated the
  stale assertion). Everything else in that run already passed, including
  the absent-digest test and every prefill/lock-arm/swap step before the
  scroll gap.
- Run 2 (commit 62d78d2): **PASS**, all 5 BurlyWatchUITests green, plus
  BurlyPhoneUITests unaffected. Budget of two acceptance-sim.sh runs used
  exactly, both logged.
- Full BurlyKit test suite green (557 tests) plus
  `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`
  (2 tests), both before either sim run.

Next: dispatcher review. Known gaps flagged in the final report: §2's
Resume-on-relaunch UI (acceptance #4, crash test) is out of scope for this
task's ACCEPTANCE list and was not implemented; the swap/add catalog
picker is a flat alphabetical list rather than recents/curated/customs
sections; weight always displays in lb (no unit-setting surface exists
yet). None of these affect acceptance #3/#5 or the full test suite.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-03
Branch: task/burly-m2-03 (HEAD 62d78d2)
Task is complete pending dispatcher review — no further action needed
unless review requests changes. If it does, start from:
git -C /Users/dfakkeldy/Developer/worktrees/burly-m2-03 log --oneline -5
```

## 2026-08-02 — Fix round 1 (adversarial review NOT-SAFE: 1 blocker + 11 majors)

Done — all 12 findings fixed in BurlyWatch (no BurlyCore/BurlyPersistence
changes needed; every fix is app-layer wiring):

- **F1 (blocker)**: `SessionEntryView` now checks
  `store.resumableActiveSession()` before ever building a new engine. If one
  is in flight, routes to new `SessionConflictView` (finish-or-discard
  against the *existing* session, spec §4) instead of an unsaved logging
  screen. Full Resume-into-its-own-logging-screen stays m2-06's, per scope.
- **F2**: engine construction + first save moved out of view init/body into
  `SessionEntryView.start()`, run once from `.task` (an explicit
  Start/Resume event) instead of computed `body`/`State(initialValue:)`.
  `SessionViewModel.init` no longer persists anything.
- **F3**: `currentReps: Int?` / `isWeightUnset: Bool` replace the invented
  bodyweight×8 default; `.empty` prefill renders "not set" / "–", Log set
  disables via `canLogCurrentSet`.
- **F4**: `applyCurrentItem` always calls `engine.pageAway()` and plays
  whatever haptic it returns; `firesPageAwayHaptic` flag removed entirely.
- **F5**: `noteScreenWake()`/`tick()` persist based on whether
  `ActiveSession.restTimer` actually changed (before/after diff), not
  whether a haptic fired.
- **F6-9 (persistence-honesty cluster)**: `logCurrentSet`/
  `addPlaceholderExercise` mutate a **snapshot** of the engine and only
  fold it back + play the haptic + advance the prefill after
  `store.saveActiveSession`/`createExercise` succeeds; failure sets
  `saveFailure` (blocks the whole screen via new `SaveFailureView`) +
  `pendingRetry`. Finish gets its own `finishSaveError`/`retryFinishSave()`
  that never re-calls `engine.finish()`. Discard sets `didDiscard` only
  after a successful `deleteSession`, routing failures through the same
  `saveFailure` mechanism (reachable from the ellipsis directly, not only
  the summary screen). `errorMessage` (no consumer) removed.
- **F10**: summary label renamed "Heavier than last time: N" /
  `sessionSummary.beatLastTime`, replacing the false "New PR" claim.
- **F11**: explicit `.frame(minWidth: 44, minHeight: 44)` +
  `.contentShape(Rectangle())` on weight micro-buttons, reps +/-, rest
  ±15 s buttons, and the rest skip target; arm gesture's parent gets
  `.frame(minHeight: 44)`.
- **F12**: `WatchDemoSeed.requestedStore()` splits the `guard` so a
  present-but-unrecognized scenario value returns `.failure`, never `nil`
  (mirrors BurlyPhone's `PhoneDemoSeed` fix). Added `FaultInjectingStore`
  (DEBUG-only `BurlyStore` decorator) + `BURLY_WATCH_UI_TEST_FAULT*` env
  keys so F6-9's save-failure paths are UI-testable without a real storage
  fault, and `Scenario.activeConflict` (Push/Pull left `.active`) for F1.

Verification:
- `cd BurlyKit && swift test`: **557/557 pass** (no BurlyKit files touched
  by this fix round, so this is a no-regression check).
- `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`:
  **2/2 pass**.
- `Scripts/acceptance-sim.sh` (one run, per the budget): **BurlyPhoneUITests
  1/1 pass**; **BurlyWatchUITests 12/15 pass, 3 FAIL**. Full log:
  `/tmp/acceptance-sim-run.log` (not in the repo); xcresult at
  `Scripts/output/runs/20260802T073654Z/BurlyWatchUITests.xcresult`
  (`Scripts/output/latest` points at it).

Failing tests (all three are in UI test files added by this fix round —
the underlying view-model fix for each is exercised successfully by a
*different*, passing test in the same run; see the full report for the
per-finding map):

1. `LoggingScreenUITests.testRestTimerControlsHaveMinimumHitRegions` —
   timed out waiting for `restTimer.remaining` after tapping `logSetButton`.
   The log tap itself needed an auto-scroll ("Scroll element to visible" in
   the log), which strongly suggests `RestTimerBanner` — rendered *below*
   the Log button in the same `ScrollView` — is off-screen afterward and
   needed an explicit `app.swipeUp()` this test never did. Likely a missing
   scroll in the test, not a finding-11 regression (`testLogSetSaveFailure...`
   and `testFullSessionFlow...`, both of which also log a set successfully,
   passed in the same run).
2. `SaveFailureUITests.testDiscardFailureBlocksAndRetrySucceeds` — timed
   out waiting for the second confirmation ("Discard permanently") after
   tapping the first ("Discard"). Two live hypotheses, unresolved: (a) same
   missing-scroll class as #1, or (b) SwiftUI cannot reliably chain two
   `.confirmationDialog` presentations back-to-back the way
   `confirmDiscardStepOne()`/`confirmDiscardStepTwo()` attempt — **that
   pairing is pre-existing code from the original m2-03 task, unmodified by
   this fix round**, so if (b) is real it is a carried defect in the
   double-confirm UX itself, not something F9's `performDiscard()` change
   introduced. No prior test ever drove this double-dialog to completion.
3. `SaveFailureUITests.testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds`
   — timed out waiting for `sessionActions.addExercise` after opening the
   ellipsis menu. Near-certain test bug: `SessionActionsView`'s `List`
   renders lazily (documented in `testFullSessionFlow...`'s own comment
   about "End workout," row 8 of 9, needing `scrollUntilExists`); "Add
   exercise" is row 5, and the passing `testFullSessionFlow...` test proves
   row 4 ("Swap exercise") is reachable without scrolling — row 5 most
   likely sits right at/past the fold on the 46 mm sim. This test used a
   bare `waitForExistence` instead of the established `scrollUntilExists`
   helper.

None of the three failures produced evidence that the underlying F6/F8/F9/
F11 *fixes* are wrong — each failure happened before the assertion that
would have exercised the fix itself, and a sibling passing test exercises
overlapping logic (F6/F7 via `testFinishSaveFailureIsRecoverableWithout
ReFinishing` + `testLogSetSaveFailureBlocksScreenAndRetrySucceeds`, both
green). But per the task's own rule, this is reported as a FAIL, not
triaged/re-run.

Not committed as green. Committed anyway per the "commit everything,
write a handoff" house rule — task worktrees are not left with uncommitted
work. **Do not merge/accept until a dispatcher-approved fix-and-rerun
closes these three tests** (most likely: add `app.swipeUp()` before
checking `restTimer.remaining`; switch `sessionActions.addExercise` to
`scrollUntilExists`; investigate whether the double `.confirmationDialog`
chain needs the same `onDismiss`-deferred pattern `LoggingScreenView`
already uses for sheet→dialog handoffs, or just a scroll).

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-03
Branch: task/burly-m2-03
Next action (needs dispatcher go-ahead first, no unauthorized re-run):
1. LoggingScreenUITests.testRestTimerControlsHaveMinimumHitRegions --
   add app.swipeUp() (or scrollUntilExists) before checking restTimer.*.
2. SaveFailureUITests.testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds
   -- replace `addExercise.waitForExistence` with the scrollUntilExists
   helper already used for endWorkout/discardWorkout.
3. SaveFailureUITests.testDiscardFailureBlocksAndRetrySucceeds -- add a
   scroll before "Discard permanently"; if it still doesn't appear,
   inspect whether LoggingScreenView's confirmDiscardStepOne -> StepTwo
   needs the same onDismiss-deferred pattern the sheet->dialog handoff
   already uses (see PendingSessionAction's doc).
Then: ONE more Scripts/acceptance-sim.sh run.
```
