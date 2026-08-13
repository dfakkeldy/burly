# HANDOFF — burly-m2-06

## 2026-08-02 — Resume flow implemented, unit suites green, acceptance-sim.sh run 1 in flight

Done:
- §2/§3 Resume flow (m2-03's explicitly-scoped-out piece): `WatchHomeViewModel
  .load()` now consults `resumableActiveSession()` before the routine list
  (new `.resumable` state) — the shell gates on an active session at
  launch/reappearance, spec §2 "Relaunch with an `.active` session in store
  → Resume screen." New `BurlyWatch/ResumeSessionView.swift` offers
  "Resume" / "Not now"; both push `HomeRoute.resume(sessionID:
  enterSummary:)` into `SessionEntryView`, which fetches the live
  `ActiveSession` via `store.activeSession(id:)` and builds
  `SessionEngine(session:)` directly — logged sets and the wall-clock rest
  timer (`RestTimerState.endDate`) come along for free, no new plumbing.
  "Not now" sets `enterSummary: true`, landing on the existing
  Finish/Keep going/Discard preview via a new `startInSummary` param
  threaded through `SessionViewModel`/`LoggingScreenView` — spec's
  "Declining resume = normal end-workout summary path" is literally the
  same summary screen "End workout" already produces, not a new one.
- `SessionViewModel`'s initial page selection now prefers the first item
  with an unlogged slot over just the first item (no-op for a fresh Start,
  lands Resume where the lifter left off on a multi-item session).
- `WatchDemoSeed` gained an opt-in on-disk store
  (`BURLY_WATCH_UI_TEST_STORE_TOKEN`, a bare token turned into a URL from
  *this process's own* `FileManager.temporaryDirectory` — never a path
  handed in from the XCUITest runner process, which is a different
  sandboxed process) so a UI test can open the same store across a real
  `XCUIApplication.terminate()` + `launch()` boundary. Seeding is now
  idempotent (`hasRoutines()` / `resumableActiveSession()` guards) so a
  reopened store isn't re-seeded into a `.duplicateID` throw. Every
  existing scenario is unaffected (still `.inMemory` when the token is
  absent).
- New `BurlyWatchUITests/ResumeUITests.swift`:
  `testCrashMidSessionOffersResumeWithLoggedSetsAndCorrectRestRemainder`
  (§2 acceptance #4 + §3 acceptance #3 combined) — Start Leg Day, log two
  sets, `app.terminate()`, sleep 6s, `app.launch()`, assert Resume is
  offered naming "2 sets logged," Resume lands on Set 3 of 3, and the rest
  countdown is lower than pre-kill by ≥4s (not frozen) and under 90s (not
  reset). `testRelaunchWithNoActiveSessionShowsRoutineListNotResumeGate` is
  a sanity guard on the same store-token mechanism.
- `SessionConflictUITests` rewritten: with the shell now gating on
  `resumableActiveSession()` before ever showing the routine list, the old
  "second Start while active" trigger point is unreachable in ordinary use
  (superseded by the Resume gate). Both tests now launch straight into the
  gate, decline to the summary, and resolve via Discard/Finish, then
  confirm Leg Day's Start proceeds normally afterward — same end guarantee
  the originals pinned. `SessionEntryView`'s own pre-check
  (`SessionConflictView`) is left in place as defense in depth, documented
  as no longer the primary guard.
- `Burly.xcodeproj/project.pbxproj` hand-patched (no synchronized groups in
  this project) for the two new files — verified via a plain `xcodebuild
  build`/`build-for-testing` before touching the sim, not just visual
  inspection of the diff.
- Store side audited, not modified: `BurlyStore.saveActiveSession` /
  `resumableActiveSession` / `activeSession(id:)` and
  `ActiveSessionJournal` (crash journaling, the bounded self-cleaning
  Resume index, the one-transaction Finish-retires-journal rule) were
  already complete and extensively tested by m1-06/m4-04 —
  `ActiveSessionTransactionTests.swift` already exercises `reopened`-store
  resume round trips, including via `resumableActiveSession()`. Nothing
  needed to change there; m2-06's gap was entirely the watch UI's
  consumption of it.
- Verification before the sim budget: `swift test --package-path BurlyKit`
  — 732 tests, all green. `BURLY_RUN_MIGRATION_SPIKE=1 swift test
  --package-path BurlyKit --filter MigrationSpikeTests` — 2 tests, green.
  `xcodebuild build` (BurlyWatch, BurlyPhone, generic destinations) and
  `xcodebuild build-for-testing` (BurlyWatch scheme, includes
  BurlyWatchUITests) all green.
- Committed: `c6f960d` on `task/burly-m2-06`.
- `Scripts/acceptance-sim.sh` run 1 of the 2-run budget launched in the
  background (log: scratchpad/acceptance-run-1.log) — result not yet known
  as of this entry.

Next: read the run 1 result. If green, task is done pending dispatcher
review. If it fails, fix and use run 2 (the last one in budget); if that
also fails, stop and report honestly per the dispatcher's guardrail rather
than attempting a third run.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-06
Branch: task/burly-m2-06 (HEAD c6f960d)
Check acceptance-sim.sh run 1: cat Scripts/output/latest/screenshots -R 2>/dev/null;
open the most recent run's .xcresult under Scripts/output/runs/<ts>/ if a
failure needs triage. If green, task is complete pending dispatcher review.
```

## 2026-08-02 — acceptance-sim.sh run 1: PASS. Task complete pending dispatcher review.

Done:
- `Scripts/output/runs/20260802T111631Z` (script printed `acceptance-sim: PASS`
  at exit; lock released cleanly). Verified independently via
  `xcrun xcresulttool get test-results summary/tests`, not just the script's
  own log line:
  - `BurlyPhoneUITests.xcresult`: 7/7 passed, 0 failed.
  - `BurlyWatchUITests.xcresult`: 18/18 passed, 0 failed — includes both
    `ResumeUITests` tests and the two rewritten `SessionConflictUITests`
    tests. `testCrashMidSessionOffersResumeWithLoggedSetsAndCorrectRestRemainder`
    (§2 acceptance #4 + §3 acceptance #3) ran in 26s — consistent with a
    real `terminate()` + 6s sleep + `launch()` round trip, not a skipped or
    trivially-fast pass.
- No fixes were needed after run 1 — the pre-sim local verification (plain
  `xcodebuild build` / `build-for-testing` for both schemes, plus the full
  `swift test` + migration spike suite) caught everything before spending
  any of the 2-run sim budget on a compile error. Run 2 was not needed and
  was not used.
- HANDOFF committed alongside the rest of the work; nothing left uncommitted.

Task status: complete pending dispatcher review. No further action needed
unless review requests changes.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-06
Branch: task/burly-m2-06 (HEAD c6f960d, HANDOFF commit on top)
Task complete pending dispatcher review — start from:
git -C /Users/dfakkeldy/Developer/worktrees/burly-m2-06 log --oneline -5
```

## 2026-08-02 — Cross-engine review round 1: 2 majors + 4 minors fixed

Cross-engine review (`/Users/dfakkeldy/Developer/health-apps/.scratch/m2-06-review-1.md`)
found the happy-path crash/resume correct but NOT-SAFE on second-order
recovery. Fixed on top of `3ca755b`, commit `9ca1b46`:

Done:
- **2.1 (major)**: unreadable active journal wedged the app behind a
  Retry-only dead end. New `WatchHomeViewModel.LoadState.unreadableSession`
  + `UnreadableSessionView` (single-tap Discard, safe because
  `deleteSession` never reads the corrupt payload). Pinned via a new
  `FaultInjectingStore.Fault.resumableActiveSessionUnreadable`.
- **3.1 (major)**: `.sessionNoLongerInFlight` was treated as endlessly
  retryable on all 3 `saveActiveSession` call sites; Finish left
  `isFinishing` stuck true. New `SessionViewModel.resolveSessionNoLongerInFlight()`
  re-reads the real stored state and routes to the terminal
  `finishedSummary`/`didDiscard` outcome. Pinned via
  `FaultInjectingStore.Fault.forceSessionOutOfFlightBeforeNextSave` (forces
  the real precondition through a real `applyPhoneEdit`, so the real store
  throws the real error).
- **1.1 (minor)**: `ActiveSession.currentItemID` (BurlyCore scaffolding,
  confirmed NOT a frozen §1/`ActiveSessionJournal` `@Model` change — only
  the unversioned `ActiveSessionScaffolding` wire struct gained an optional
  field) now journals the viewed item; `SessionEngine.setCurrentItem(_:)`
  records it on every page move. Pinned at the BurlyCore + BurlyPersistence
  layer (fast, no sim); no UI-level pin because Push/Pull's digest-less
  items need `XCUIElement.increment()`, unavailable on this watchOS XCTest
  SDK (confirmed by an actual build failure, not a guess).
- **4.1 (minor)**: on-disk store token is now validated as a `UUID` before
  being used in a path component (closes the `/`/`..` injection vector by
  construction). Pinned by a malformed-token UI test.
- **4.2 (minor)**: `.activeConflict` no longer re-seeds after the fixture
  was legitimately resolved on an on-disk store — a companion marker file
  next to the store records "already seeded," independent of session
  state. Pinned by a discard-then-relaunch UI test.
- **6.1 (minor)**: restored `SessionConflictView` regression coverage via a
  new wall-clock-gated fault
  (`injectActiveSessionOnLateResumableCheck`) that deterministically
  constructs the late-active-session race its defensive pre-check exists
  for. Deliberately NOT call-count-gated (risk: an early `scenePhase`-
  triggered extra shell `load()` could consume the count) — see that
  case's doc for the reasoning.
- New scenario `WatchDemoSeed.Scenario.activeLegDay` (Leg Day active
  instead of Push/Pull, so a resumed session has a digest and Log set is
  immediately enabled — needed once `.increment()` turned out unavailable).
- Verification: `swift test` 735 tests green (was 732); migration spike
  green; `xcodebuild build`/`build-for-testing` both schemes green before
  spending any sim budget.
- `Scripts/acceptance-sim.sh` run: `Scripts/output/runs/20260802T120939Z`,
  script printed `acceptance-sim: PASS`. Verified independently via
  `xcrun xcresulttool get test-results summary/tests` (not just the
  script's own log line):
  - `BurlyPhoneUITests.xcresult`: 7/7 passed, 0 failed.
  - `BurlyWatchUITests.xcresult`: **25/25 passed, 0 failed** (up from 18) —
    all 7 new/changed tests for this round passed:
    `testUnreadableActiveJournalOffersDiscardAndAppIsUsableAfterward` (2.1,
    8s), `testSessionInvalidatedDuringLogRoutesToTerminalStateNotRetryLoop`
    (3.1, 10s), `testSessionInvalidatedDuringFinishClearsIsFinishingAndRoutesToTerminalState`
    (3.1, 19s), `testMalformedStoreTokenFallsBackToInMemoryStore` (4.1, 4s),
    `testActiveConflictDoesNotReseedAfterDiscardOnRelaunch` (4.2, 18s),
    `testLateActiveSessionRaceReachesSessionConflictViewAndDiscardResolvesIt`
    / `...AndFinishResolvesIt` (6.1, 13s/11s). Only one attempt was needed;
    this round's second sim-run budget slot was not used.

Task status: **CORRECTION (see 2026-08-02 round 2 entry below) -- this was
overstated.** All 32 sim tests were genuinely green, but "fully closed" was
this implementer's own verification claim, not a review verdict. The
follow-up cross-engine re-review found 3 of the 6 findings not actually
closed (1 major, 2 minor) plus 1 new coverage gap -- see below. The correct
framing at this point should have been "all fixes attempted, sim green,
pending re-review," not "fully closed."

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-06
Branch: task/burly-m2-06 (HEAD 9ca1b46, HANDOFF commit on top)
Review round 1 fixes sim-green, pending re-review — start from:
git -C /Users/dfakkeldy/Developer/worktrees/burly-m2-06 log --oneline -5
```

## 2026-08-02 — Cross-engine re-review round 2: 1 major + 2 minors + 1 new-defect fixed

Re-review (`/Users/dfakkeldy/Developer/health-apps/.scratch/m2-06-review-2.md`)
confirmed 3 of round 1's 6 findings genuinely closed (finding 2 —
`.sessionNoLongerInFlight`; finding 3 — current-item persistence, no
schema change; finding 4 — store-token UUID validation) and found 3
NOT-CLOSED plus 1 new defect. Fixed on top of `b85bcb1`, commit `63ead7f`:

Done:
- **§1 (major)**: unreadable-journal recovery was wired at the primary
  launch path only. Two secondary `SessionEntryView` call sites --
  the defensive new-session preflight (`resumableActiveSession()`) and
  `.resume`'s own fetch (`activeSession(id:)`) -- still folded the error
  into generic `.failed` (a dead-end `StoreUnavailableView`). Both now
  catch `.unreadableActiveSessionJournal` distinctly via a new
  `SessionEntryView.Phase.unreadableSession`, reusing the same
  `UnreadableSessionView` Discard recovery; `discardUnreadableSession(_:)`
  deletes the session then `dismiss()`s back to the shell. Pinned by two
  new faults (`injectUnreadableActiveSessionOnDefensivePreflight`,
  `resumeFetchUnreadable`) and two new `SessionRecoveryUITests`.
- **§5 (minor)**: `activeConflict`'s seed marker now writes and checks
  `FileManager.createFile`'s result **before** the seed commits (was:
  commit-then-unchecked-marker-write) -- fails closed
  (`SeedError.activeConflictMarkerWriteFailed`) rather than risking a
  reseed. Inverts the failure mode to "at most once."
- **§6 (minor)**: the `SessionConflictView` race fault was wall-clock-gated
  (fire ≥1.5s after construction) -- correctly flagged as flaky, since the
  shell can call `resumableActiveSession()` more than once before the
  lifter's tap (`.task`, `RoutineListView.onAppear`, an unpredictably-
  delayed `scenePhase` transition). Replaced with a caller-identifying
  check (`Thread.callStackSymbols` contains `"SessionEntryView"`) --
  deterministic, no timing assumption. Removed the now-unneeded explicit
  sleeps from the two tests.
- **New defect**: `resolveInitialItem` (round 1's fix) had no pin proving
  the restored page beats "first incomplete" -- the single-item Leg Day UI
  test can't distinguish the two. Relocated the policy from
  `SessionViewModel` (untestable -- no unit-test target hosts `BurlyWatch`)
  to `ActiveSession.initialPageItemID` (BurlyCore, testable via
  `swift test`) -- pure policy with no view/store dependency, so this is
  also the architecturally correct home per this codebase's "engine owns
  logic" convention. Pinned by a new BurlyCoreTests case with a 3-item
  routine that fails under the old algorithm.
- Verification: `swift test` 736 tests green (was 735); migration spike
  green; `xcodebuild build`/`build-for-testing` both schemes green before
  spending any sim budget.
- `Scripts/acceptance-sim.sh` run launched in the background (log:
  `scratchpad/acceptance-run-3.log`) -- result pending as of this entry.

Run 3 result: **FAIL** (`runs/20260802T125421Z`, exit 65). 3 failures, all
in tests using the NEW `Thread.callStackSymbols.contains("SessionEntryView")`
gate (`injectActiveSessionOnLateResumableCheck`,
`injectUnreadableActiveSessionOnDefensivePreflight`): the routine list
never rendered at all in `testUnreadableJournalAtDefensivePreflightOffersDiscardAndAppIsUsableAfterward`
(15s timeout on `routineRow.Leg Day.name`), meaning the fault fired on
`WatchHomeViewModel.load()`'s own first call, not `SessionEntryView`'s --
deterministically, not a rare race. Diagnosis: `dladdr`-based call-stack
symbolication in an unoptimized Swift build is nearest-symbol best-effort
matching, not an exact call graph, and evidently misattributed a
shell-side frame. Abandoned outright.

Fix (commit `e49dccb`): replaced the caller-identification gate with a
**quiet-period gate** -- `FaultInjectingStore` tracks
`lastResumableActiveSessionCallAt` and fires only once ≥1.5s have passed
since the *previous* call to that exact method (not since construction,
not identifying the caller). Every real shell-triggered call happens
within a fraction of a second of the one before it (synchronous SwiftUI
lifecycle events clustered at launch); only a call arising well after
that cluster settles -- an XCUITest's deliberately-delayed tap -- clears
the gate. The three affected tests now sleep 4s before tapping. Re-ran
`swift test` (736, green) + migration spike (green) + both
`xcodebuild build`/`build-for-testing` (green) before spending the second
and final acceptance-sim.sh attempt for this round.

Next: read run 4's result (this round's 2nd and final sim attempt per the
2-run budget). If green, report done. If it fails too, stop and report
per the dispatcher's guardrail -- no further attempts without dispatcher
triage.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-06
Branch: task/burly-m2-06 (HEAD e49dccb)
Check the sim run: cat /private/tmp/claude-501/-Users-dfakkeldy-Developer-health-apps/6797db06-aea3-4cdc-acde-97a45503f65e/scratchpad/acceptance-run-4.log | tail -60
This was the 2nd (final) acceptance-sim.sh attempt for review round 2 --
if it also failed, do not run a 3rd without dispatcher input.
```

## 2026-08-02 — dispatcher: run 4 VOIDED (infra), attempt budget restored

Done:
- Run 4 (`20260802T131928Z`) is **not a verdict** and does not count
  against the 2-run budget. It hung ~59 min and took
  `** BUILD INTERRUPTED ** / Terminated: 15` during the *watch* build,
  after the phone tests. Phone xcresult is corrupt; no watch xcresult.
  Cause was host RAM thrash (swap 19.7 GB used / 797 MB free on a 16 GB
  box, load 95-480), not `e49dccb`. Box has since been restarted.
- Re-ran the SPM half engine-blind on the healthy box at `e49dccb`:
  `swift test` = **736 tests / 77 suites passed in 7.155 s**;
  migration spike = **2/1 passed**. Confirms the pre-sim claim.
- Sim half is the only gate left. It is queued behind an unrelated Echo
  test loop; a watcher fires it once the host is quiet (solo-sim rule).

Next: read the solo sim result. Green -> Codex re-check of the §1
residual (unreadable-journal recovery), then merge (unblocks m2-04).
Red -> triage before spending another attempt.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/worktrees/burly-m2-06
Branch: task/burly-m2-06 (HEAD e49dccb)
Sim log: scratchpad/m2-06-sim.log   Watcher: scratchpad/echo-watch.log
Run the solo acceptance-sim only when no other xcodebuild is live.
```
