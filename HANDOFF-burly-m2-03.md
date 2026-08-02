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

Resume (superseded by the 2026-08-02 Round B entry below):
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

## 2026-08-02 — Round B (authorized): the three fixes applied, still NOT green

Dispatcher authorized fixing the three failing tests with a one-run budget.
All three were addressed; **the run (`Scripts/output/runs/20260802T075453Z`)
still failed with the exact same three tests failing**, but the new
evidence overturns part of the Round A diagnosis. Reported honestly per
"if anything still fails, stop — no rerun." No further sim runs performed.

What was done:

1. **`testRestTimerControlsHaveMinimumHitRegions`**: replaced the bare
   `remaining.waitForExistence(timeout: 5)` with
   `scrollUntilExists(app, remaining)` (8 swipe-up attempts over ~17s).
   **Still failed, same assertion.** New evidence this time: the scroll
   loop ran its full 8 attempts and `restTimer.remaining` never existed at
   any scroll position. `ExercisePageView`'s `ScrollView` wraps a **plain
   `VStack`, not a `LazyVStack`** — unlike `SessionActionsView`'s `List`
   (which genuinely defers off-screen rows), a plain `VStack` constructs
   all children immediately regardless of scroll position, and
   `XCUIElement.exists` does not require on-screen visibility. So this was
   never actually a scroll problem — the Round A diagnosis was wrong. The
   real question is why `viewModel.isRestRunning` (or the log itself)
   isn't true after tapping `logSetButton`, and that remains open: a
   structurally near-identical test in the same run,
   `testSummaryNeverShowsInventedPRLabel` (tap routine row -> wait for
   `logSetButton` -> tap it, no extra settling wait), logs successfully and
   reaches "End workout" without incident in the same run. What's
   different about this one is unclear without a live debugging session
   (screenshot/accessibility-snapshot at the failure point) that a blind
   fix-and-rerun can't provide.

2. **`testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds`**:
   replaced `addExercise.waitForExistence(timeout: 5)` with
   `scrollUntilExists(app, addExercise)`. **Still failed** — new failure
   text this time: `"Expected to be able to scroll to 'Add exercise'"`,
   after 8 full swipe-up attempts (~17s) that never revealed
   `sessionActions.addExercise`. Same conclusion as #1: this was not
   purely a scroll/off-screen problem the way "End workout" (row 8) and
   "Discard workout" (row 9) are elsewhere in this suite — something is
   preventing that row from existing in the tree at all in this specific
   flow (ellipsis -> "Add exercise", immediately after Start, no fault
   active yet since `createExercise` only fails on the row *after* this
   one is tapped). Root cause not yet identified.

3. **`testDiscardFailureBlocksAndRetrySucceeds`**: researched first, per
   the dispatcher's instruction, before touching code. Confirmed via a web
   search that chaining two SwiftUI presentation modifiers (toggling one
   `isPresented` binding off and a second one on in the same synchronous
   state update) is a documented, known-unreliable pattern across
   `.sheet`/`.alert`/`.confirmationDialog` — the same class of problem this
   file already works around for the sheet -> confirmationDialog handoff
   (`PendingSessionAction` + `onDismiss`). Concluded this is a **real,
   pre-existing defect** in `LoggingScreenView`'s double-confirm discard
   flow (`confirmDiscardStepOne()` flips `isShowingDiscardStepOne` off and
   `isShowingDiscardStepTwo` on in one call), not a test artifact, and not
   something this task's earlier fix rounds introduced. Fix applied:
   merged the two `.confirmationDialog` modifiers into **one**, whose
   `isPresented` binding (`isShowingDiscardStepOne || isShowingDiscardStepTwo`)
   never toggles off between the two steps, with title/actions computed
   from which step is active — so SwiftUI only has to update an
   already-presented dialog's content, never chain a second presentation.
   **Still failed at the same point** (waiting for "Discard permanently"
   after tapping "Discard"). This means the fix as implemented did not
   resolve it. Revised hypothesis: SwiftUI's `.confirmationDialog` may not
   live-update its title/actions builder while already presented on this
   watchOS version/wersion — i.e., the dialog may render once at
   presentation time and not re-diff on a later state change even though
   `isPresented` never went false. That would need a structurally
   different fix (e.g., drop `.confirmationDialog` for this flow and use a
   dedicated full-screen confirm view the way the m2-03 review's blocker
   fix already does for `SessionConflictView`, which has no
   presented-modifier chaining at all) — not verified, because no further
   sim runs are authorized this round.

No regressions: all 12 previously-passing tests (the 9 cleanly-fixed
findings' pins plus the 3 that already passed in round A) still pass,
including `testFinishSaveFailureIsRecoverableWithoutReFinishing` and
`testLogSetSaveFailureBlocksScreenAndRetrySucceeds` (F6/F7) and both
`SessionConflictUITests` tests (F1). `BurlyKit` (557/557) and the
migration spike (2/2) still green, unaffected (still no BurlyKit changes
in this task).

Verification this round:
- `cd BurlyKit && swift test`: 557/557 pass.
- `BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`: 2/2 pass.
- `Scripts/acceptance-sim.sh`: BurlyPhoneUITests 1/1 pass. BurlyWatchUITests
  **12/15 pass, 3 fail** (same three as round A, different/more informative
  failure signatures — see above). Exit 65, `acceptance-sim: FAIL`.
  Result bundle: `Scripts/output/runs/20260802T075453Z/BurlyWatchUITests.xcresult`.

Not merge-ready. This needs a **live debugging session** next (attach to
the sim, screenshot/dump the accessibility tree at the moment of failure
for `testRestTimerControlsHaveMinimumHitRegions` and
`testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds`, and confirm
or refute the "confirmationDialog doesn't live-update" hypothesis for
`testDiscardFailureBlocksAndRetrySucceeds`) rather than another blind
fix-and-rerun cycle — two rounds of plausible-but-wrong static diagnosis
in a row is a signal to stop guessing, per the global "after two failed
approaches, stop adding machinery, reassess" rule.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-03
Branch: task/burly-m2-03 (HEAD after this entry's commit)
Two fix rounds (A, B) have each closed some failures but left the same
three tests red, with contradicting diagnoses each time. Needs a live
simulator debugging session (screenshots / accessibility snapshot at the
failure point), not another blind code-guess-and-rerun:
1. `testRestTimerControlsHaveMinimumHitRegions` /
   `testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds`: attach to
   the sim mid-test (or add explicit screenshot attachments right before
   the failing assertion) to see what's actually on screen when the
   expected element doesn't exist -- confirm whether logging/navigation
   genuinely didn't happen, or something else is going on.
2. `testDiscardFailureBlocksAndRetrySucceeds`: verify whether the merged
   single-`.confirmationDialog` actually live-updates its title/actions in
   place on watchOS 26, or replace it with a dedicated full-screen confirm
   view (no `.confirmationDialog` at all) modeled on `SessionConflictView`.
Do not spend a third acceptance-sim.sh run on another guess without first
getting a screenshot/log of the actual on-screen state at failure time.
```
