# HANDOFF — burly-m2-04 (watch session actions: swap / move / skip)

## 2026-08-13 — watch suite executed for the first time; 5 failures, root cause open

Done:
- `Scripts/acceptance-sim.sh` ran at `02e8011`, run dir
  `Scripts/output/runs/20260813T053759Z`, rc=65.
- **Phone 8/8 passed. Watch 32 tests, 27 passed, 5 failed.**
- The significant part: **the watch suite was reached at all.** For two rounds
  it never was — `acceptance-sim.sh` aborts after a failing phone suite, so a
  green phone result was being misread as whole-run coverage. The five failing
  tests are exactly the five that had never once executed.

The five failures, two distinct causes:

1. Four of them — `testFullSessionFlowLogSwapFinishShowsCorrectTotals`,
   `testSwapExerciseRelocksWeightControl`, `testMoveUpChangesTheRenderedPagerOrder`,
   `testSkippingMiddleExerciseAdvancesAndKeepsRenderedOrdinalsDense` — all die in
   the same helper, `selectPickerExercise`, duplicated verbatim at
   `BurlyWatchUITests/LoggingScreenUITests.swift:415` and
   `BurlyWatchUITests/SessionActionsUITests.swift:206`:
   `app.searchFields.firstMatch` not found within 5s.
2. The fifth — `testSkipReturnsToEmptySessionAndDisablesItemActionsWithoutCurrentItem`
   — fails earlier and separately at `SessionActionsUITests.swift:55`:
   `sessionActions.skipExercise` not reachable via `scrollUntilExists`.

Both features exist in the product — `.searchable(text: $searchText)` at
`BurlyWatch/Session/ExercisePickerView.swift:46`, the skip row at
`BurlyWatch/Session/SessionActionsView.swift:84`. So the leading hypothesis is a
test-harness defect: watchOS does not surface `.searchable` as an XCUIElement
`searchField` the way iOS does.

**That hypothesis is NOT established.** An identical failure message would be
produced if the picker sheet simply never presented after `addExercise.tap()`.
No screenshots exist to discriminate — capture only runs after a passing suite.
Do not write this up as "the product is fine" until an element-tree dump
(`app.debugDescription` at the failure point) settles which it is.

Next:
- Dispatch a diagnose-then-fix round that dumps the watch accessibility tree at
  the point of failure BEFORE changing any helper.
- If it is the harness, fix `selectPickerExercise` once — it is duplicated in
  two files, so fix the duplication at the same time.
- Re-run the sim. Sim slot is contended; m3-01 is ahead in the queue.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04 at 02e8011, tree clean.
Next action: dispatch watch-UI diagnosis — dump app.debugDescription at LoggingScreenUITests.swift:415
to establish whether the picker sheet presented, before touching selectPickerExercise.
```
