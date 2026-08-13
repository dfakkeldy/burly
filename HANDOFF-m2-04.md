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

## 2026-08-13 — measured M directly; "first mutation" story caught and killed

Done:
- Stopped waiting on the diagnosis engine (three rounds of "0 tests executed"
  from its sandbox; its last act was launching the full acceptance sim, which
  cannot answer the question) and measured the value myself.
- Probe: printed `exercisePage.name`'s accessibility value — which IS
  `Exercise N of M` — after each mutation, ran the sim, reverted the probe.
  Baseline unchanged by it (32 tests, 3 failures, same three), so the readings
  hold. Run dir `20260813T0605*`, log `scratchpad/m2-04-probe-run.log`.

      PROBE88-add1   label=Back Squat  value=Exercise 1 of 1    did NOT land
      PROBE88-add2   label=Pull-Up     value=Exercise 2 of 2    DID land
      PROBE118-add1  label=Back Squat  value=Exercise 1 of 1    did NOT land

  Corroborated by the tree at the same instants: `value: page 1 of 1`.
  **The mutations are not landing at all** — not landing-then-failing-to-route.

- `:88`'s `app.swipeDown()` is INNOCENT, and I had it filed as a harness
  gesture bug for two rounds. It fails because Barbell Bench Press was never
  added, so there is no middle page. The retarget work in the reverted round
  was "fixing" a test that was telling the truth.

The exact pattern, including the passing tests that constrain it:

      LANDS   addSet                                  (first mutation of its test)
      LANDS   add via `exercisePicker.addPlaceholder`  (first mutation of its test)
      LANDS   add "Pull-Up" via picker row            (second add in `:88`)
      DROPPED skip                                     (`:60`, first mutation)
      DROPPED add "Barbell Bench Press" via picker row (`:118` and `:88`)

I first wrote this up as "the first session-actions mutation after launch is
silently dropped" and that is FALSE — `addSet` and the placeholder add are both
first mutations and both land. Caught before dispatching. The real pattern is
narrower: skip, and the picker-row add of Barbell Bench Press.

Unexplained lead, NOT a conclusion: Barbell Bench Press is tapped ~3s after the
picker opens (it sits near the top, so it is hittable at once) while Pull-Up is
tapped only after ~30s of drags. The add given a long settling period lands.
That does not obviously explain `:60`, where `addSet` and `skip` are reached
identically and only `skip` fails — so either two causes, or one of these
readings is misread.

Next:
- Round 4 dispatched (gpt-5.6-sol, --write): establish the mechanism with
  evidence, THEN fix. Brief carries the correction that the swipe is innocent
  and forbids test edits to close the gap.
- Verify engine-blind afterwards. Prediction to check: all three go green with
  zero test edits.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04, tree clean.
Next action: read scratchpad/m2-04-fix4.log; review the diff; then run
`scratchpad/slot-retry.sh -- timeout -s TERM 2700 ./Scripts/acceptance-sim.sh`
and read the xcresult bundles directly — do not trust any reported count.
```

## 2026-08-13 — RETRACTION: every mutation lands; the render is stale

Done:
- Wasted a full sim cycle first: I captured Codex's probe diff, killed it,
  then launched the sim without re-checking the tree AT LAUNCH. Codex had
  reverted the instrumentation in between — doing what my own brief told it
  to. The 06:05 build had zero probes, so that run just re-derived 29/32.
  Rule now: assert the probe marker in the source at launch AND in the built
  binary after the build. A missing-probe build and a probe-that-never-fires
  are indistinguishable from the logs.
- Re-applied the diff and ran a TARGETED 5-test run instead of the 32-test
  acceptance sim — the right instrument for iterating a diagnosis. Verified
  34 PROBE strings in `BurlyWatch.debug.dylib` before trusting anything.
- Found the capture channel: the **host** unified log. Simulator apps are host
  processes, so their `os_log` output never reaches the guest device log —
  which is why my earlier four-place search came up empty.

**The mutations all land. I had this exactly backwards.**
Evidence, 30 lines at `scratchpad/m2-04-probe-evidence.txt`:

      skip enter  items=1  current=DCD4F76E…
      skip mutated items=0
      skip exit   current=nil  items=0
      add mutated items=2  new=D195E593…     (Barbell Bench Press)
      add mutated items=3  new=A3C4EA2C…     (Pull-Up)

Zero throws logged at any site, so `try?` was never swallowing anything.
`SessionMutator`, `SessionEngine` and `SessionViewModel` are all CORRECT.
After skip the model holds zero unskipped items and a nil `currentItemID`
while the screen still shows `Back Squat / Exercise 1 of 1` and never renders
the empty-session branch. **The defect is entirely view refresh.**

This retracts the previous entry's central finding and everything under it.
The ":88 swipeDown is innocent" verdict survives, but its reason was wrong:
the add lands, and the swipe finds no middle page because the pager never
re-rendered the second page.

**It is intermittent.** `testMoveUpChangesTheRenderedPagerOrder` PASSES in the
targeted run — 3 passed, 2 failed (`:60`, `:88`) — having failed in every
full-suite run, with no product change. The probes show its add landing and
the pager then correctly rendering `Exercise 2 of 2`. So observation usually
delivers and sometimes does not, and the miss rate rises under full-suite
load. Consequence: **a green targeted run proves nothing; only the full watch
suite gates this.**

Two-instance hypothesis refuted: the view model's `ObjectIdentifier` is stable
across every mutation within each test process.

Next:
- Fix round on the view-refresh defect, with the corrected evidence.
- Verify with the FULL acceptance sim, not the targeted run.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04, tree clean.
Probe instrumentation preserved at scratchpad/m2-04-codex-probe.diff; capture via
`/usr/bin/log stream --predicate 'eventMessage CONTAINS "PROBE-M2-04"'` on the HOST.
Next action: review the fix round's diff, then run the FULL acceptance sim via
`scratchpad/slot-retry.sh -- timeout -s TERM 2700 ./Scripts/acceptance-sim.sh`.
```

## 2026-08-13 — round 6 dispatched: mechanism established by read-site partition

Done: Found the discriminator. `viewModel.items` is read at exactly three sites
— `ExercisePageView.swift:58` (ordinary body, tracked) and
`LoggingScreenView.swift:165`/`:169`, both inside the `TimelineView` content
closure at `:163`. `context.date` is used at exactly one site (`.onChange` at
`:180`), so that `TimelineView` renders nothing time-dependent — it is a 1 Hz
timer that wraps the whole pager. Reads inside it never register an observation
dependency. The four passing paths either don't touch `items` or also write
`saveFailure` (read at `:52` in the real body), which forces a re-render that
re-reads `items` — they refresh by accident. 7 of 7 paths explained, and it
explains the isolation-vs-full-suite intermittency too. The whole-value-assign
lead from the previous entry is dead (`addSet` mutates in place and passes).
Round 6 dispatched to codex/gpt-5.6-sol from clean `4de3ce8`.

Next: Read the round-6 report, then gate on the FULL acceptance sim in the
09:00 window. `slot-retry.sh` widened to `MAX_ATTEMPTS=90` (135 min) so it can
bridge the 07:00→09:00 closed window; the old 45 min could not. Pre-flight rule
still binding: assert the fix in SOURCE at launch and in the BUILT dylib after,
or the result is inconclusive.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m2-04, branch task/burly-m2-04.
Read the round-6 Codex report, then run the full acceptance sim SOLO via
Scripts/acceptance-sim.sh wrapped in scratchpad/slot-retry.sh. Gate is 32/32
watch + 8/8 phone with zero test edits. Verify the fix is in the shipped
BurlyWatch.debug.dylib before trusting any result.
```

## 2026-08-13 — round 9 committed, gate queued behind stage 1

Done: Stopped guessing and measured. A probe run dumped the settled
accessibility tree at all three failure points (phone 8/8, watch 30/32) and
split them into three different kinds of finding: testMoveUp now passes but
only because the probe doubled the window to 10s, so that is a LATENCY
reading and not a fix; line 86 is a harness defect (the pager was correctly
at page 3 of 3 and app.swipeDown() just does not move a crown-driven
PUICPageViewController); line 60 is the real product defect, where the view
never re-rendered at all. Root cause of findings 1 and 3: loggingBody read
pagerItemIDs outside the closure correctly, but the value was captured INTO
the TimelineView content closure, so the page set was frozen at the last body
evaluation while the 1 Hz tick re-rendered the stale snapshot. Round 9
(b474443) moves the pager into the enclosing body and demotes the timeline to
a background that only drives tick(). All 16 source invariants re-verified by
the dispatcher, not taken from the engine's report.

Next: gate-round9.sh runs after the three-gate chain finishes (stage-2
follower is already waiting on the chain PID; nothing to launch by hand). Its
pre-flight inverts round 7's expectations on purpose -- pagerItemIDs must now
be read TWICE in the body and TabView must appear ZERO times inside the
timeline -- and it fails the run if either assertion in the middle-exercise
test goes missing or any XCTSkip appears.

Resume:

```
The m2-04 round-9 gate result is in scratchpad/gate-round9.log. Read the
failure TEXT before the exit code -- an infrastructure wedge is inconclusive,
not red -- and pull exact failing lines from the EXACT FAILING LINES section,
never from the xcresult summary, which has no line numbers. If green, open the
PR from /Users/dfakkeldy/Developer/worktrees/burly-m2-04 on task/burly-m2-04
and have it delete HANDOFF-m2-04.md. Do not commit into that worktree while
its gate is running.
```

Do not read accessibility text as a live model read. It is a snapshot of the
last render. This task paid for that lesson twice.
