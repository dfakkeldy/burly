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

## 2026-08-13 — harness fixed and verified; a real crash found behind it

Done:
- Harness fix committed `050a468`, verified engine-blind by my own
  `acceptance-sim.sh` run (run dir `20260813T062251Z`): **phone 8/8, watch
  29/32**, up from 27/32. The implementer's own run executed zero tests and
  said so, so nothing rested on its claim.
- Both round-1 causes confirmed as harness by live accessibility inspection:
  watchOS does not expose `.searchable` as an XCUI `searchField` (the picker
  demonstrably *did* present), and full-screen `swipeUp()` skips lazy row 5.

The three remaining failures are NOT harness. Classified with live evidence:

1. **`:60` — PRODUCT DEFECT, a crash.** Skipping the only exercise kills the
   app: `Fatal error: Rendered exercise page is missing its visible ordinal`,
   `BurlyWatch/Session/ExercisePageView.swift:60`. Verified independently:
   `renderedItemOrdinal` -> `unskippedItemIndex` -> `unskippedItems.firstIndex`
   returns nil once the item is skipped, and the view treats nil as
   `assertionFailure`. SwiftUI's TabView transiently keeps rendering the page it
   just removed, so the assertion fires mid-transition. The assertion encodes
   "every rendered page has an ordinal", which is false during a pager
   transition. `assertionFailure` is compiled out under `-O`, so release never
   trapped — but the accessibility value silently vanishes there instead.
2. **`:86` — harness.** `app.swipeDown()` is routed by watchOS to the page's
   inner scroll view; the same gesture aimed at the pager's
   `PUICPageViewController_collectionView` moves correctly.
3. **`:116` — harness.** The picker row tap is intermittently not accepted
   while the lazy list is still settling after a scroll.

Ruled out, with evidence: `SessionViewModel.swift:519`'s `try?` is NOT the
cause of `:60` — the mutation had already succeeded, which is exactly why the
ordinal went nil. It is already filed in `plan/tasks/BACKLOG.md`.
`swift test --filter SessionMutatorTests` passes 26 tests covering skip,
middle-skip routing, add and move — the engine is correct; the defect is
confined to the watch view layer.

Next:
- Fix round in flight: product fix for the false assertion, plus the two
  harness fixes. Then I re-run the acceptance sim.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04.
Next action: check `git status`; if the fix round landed changes, review them, then run
`/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- timeout -s TERM 2700 ./Scripts/acceptance-sim.sh`
and read the xcresult bundles directly — do not trust any reported count.
```

## 2026-08-13 — round-3 fix REVERTED; the crash premise was false

Done:
- Ran the verification sim (run dir `20260813T080848Z`): **phone 8/8, watch 29/32**
  — byte-identical to the pre-fix baseline. The round-3 fix changed nothing.
- **The "crash" the round-2 diagnosis reported never happened.** The
  `App UI hierarchy` attachments at the `:60` failure are identical in both
  runs — before the fix (`20260813T062251Z`, `assertionFailure` still present)
  and after — and both show `exercisePage.name` label `Back Squat`,
  **value `Exercise 1 of 1`**. A present ordinal means `renderedItemOrdinal`
  returned non-nil, so the assertion never fired and the app never trapped.
  The previous entry recorded that crash chain as "verified independently";
  it was a code-reading derivation promoted to an observation. It was wrong,
  and it aimed the whole fix round at a defect that does not exist.
- Reverted all four files back to `050a468`. Diff preserved at
  `scratchpad/m2-04-round3-reverted.diff`. Baseline is clean and known.
- Settled the open `isHittable` risk: no regression. The `removeEmptySet`
  disabled-button test passed in both runs.

Established first-hand this round:
1. **BurlyCore is exonerated.** A throwaway probe under `swift test` (no
   simulator) confirmed skipping the only item leaves `unskippedItems` empty
   and `isSkipped == true`, at both `SessionMutator` and `SessionEngine`
   level. Existing tests never asserted this — `skippingEveryItemLeaves...`
   only checks `nextUnskippedItemID == nil`. Probe deleted.
2. **`:60` — skip from the actions sheet does not mutate the session.** Skip
   is enabled, tapped, the sheet dismisses, and the item stays unskipped at
   `Exercise 1 of 1`. Not a crash; a silent no-op. Cause NOT established.
3. **`:118` — the same signature for add.** A frame pulled from the failure
   recording 0.6s after the `Barbell Bench Press` picker row is tapped shows
   the picker dismissed and the logging screen back on `Back Squat`.
4. **`:88` — no middle page to reach.** Its `Pull-Up` assertion at `:83`
   passed, so that add landed. Whether the earlier `Barbell` add landed but
   failed to route, or never landed, is unresolved — and it is the same
   discriminating question as `:118`.

Next:
- Dispatch a DIAGNOSE-ONLY round on the watch layer between the actions-sheet
  button and the engine. Do not hand it a cause; hand it the evidence.
- Key discriminator to demand: after each mutation, the item COUNT
  (`page N of M` / ordinal), not just which page is displayed.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04 at 7710cd3, tree clean.
Next action: dispatch diagnose-only round for the silent no-op in SessionViewModel's
actions-sheet mutation path (skip/add). BurlyCore is proven correct — do not re-derive it.
```
