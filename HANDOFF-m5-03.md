# HANDOFF — burly-m5-03 (History list + session detail editing + naming queue)

## 2026-08-13 — implementation landed, NOT yet verified by the dispatcher

Done: Dispatched to codex/gpt-5.6-terra from a fresh worktree off `main`
(eff301d). It built the §6 history surface: week-grouped reverse-chronological
list with duration/volume/PR/edited glyph, a session detail editor
(set edit, warmup toggle, add/remove/reorder sets and exercises, catalog
picker, notes, visible revision), a naming-queue banner, and store-level
placeholder naming/merge in `BurlyStore`/`SwiftDataStore`. Kept all four
m5-01 review properties in `HistoryTabView` (lazy `.task` load, domain-level
retry, shared `EmptyStateView`, stable row identifiers). Engine reports
757 `swift test` passing; **I have not re-run that myself yet.** The pbxproj
change is 4 lines registering the one new source file into the BurlyPhone
target — I verified it links no new module and `plutil -lint` passes.

Two gaps the engine declared rather than hid:
- §6 #4's sync-round-trip half is unreachable: `BurlyPhoneSync`,
  `BurlyWatchSyncRuntime` and `BurlyImport` have **zero** hits in the pbxproj,
  so no sync runtime is in either shipping app target. Merge/re-pointing is
  proven at module level (2 tests); the round-trip is not.
- Session deletion is absent. §6 requires deleting a session to delete the
  linked HKWorkout too, and no HealthKit deletion service is wired to the
  phone. A store-only delete would have violated the §4 rule, so it was left
  out. This is a real hole in §6 and needs its own decision.

Next: Re-run `swift test` engine-blind in `BurlyKit/` (deferred while the
m2-04 acceptance sim held the box — swap was under 512 MB). Then gate §6
#1/#4/#5 on the full acceptance sim, which needs xcui coverage that does not
exist yet for the new surfaces.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m5-03, branch task/burly-m5-03.
Run `swift test` from BurlyKit/ and confirm the count independently (engine
claimed 757 passing, baseline main is 755 + 2 new ExerciseNamingTests). Then
decide whether §6 #1/#5 need new xcui tests before the sim gate is meaningful.
```

## 2026-08-13 — xcui coverage landed and test hooks pulled out of release UI

Done: Verified the xcui round engine-blind — `swift test --disable-sandbox`
gives 757 in 81 suites, exit 0, and the test diff is +89/−0, so nothing was
weakened. Committed `c6b86c5`. Then found two rows that shipped test hooks to
users (visible revision counter, raw HealthKit UUID); §6 says the edit marker
is "one glyph — not a changelog", so that is a spec violation, not taste.
Both are now `#if DEBUG` in `2f1d799`, identifiers byte-identical, no test
file touched. Confirmed both schemes' TestAction is Debug and
`acceptance-sim.sh` passes no `-configuration`, so the hooks exist in the
build the UI tests run against.

Deletion routing resolved: §6's "deleting a session deletes both" needs NO new
task. `burly-m3-04` (Metadata linking + delete propagation, §4 acceptance #2,
pending) already owns it — §4 states it outright and BACKLOG.md already routes
the query-and-delete-by-ExternalUUID machinery to m3-03/m3-04. m5-03 is right
to decline it; its acceptance is §6 #1/#4/#5 only.

Next: The sim gate. The box is committed to the m2-04 round-7 acceptance cycle
first (window 09:00–15:00), so m5-03's gate queues behind it. Nothing else
blocks this task.

Resume:
```
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m5-03, branch task/burly-m5-03 at 2f1d799.
Once the m2-04 gate releases the box, run Scripts/acceptance-sim.sh solo via
xcode-build-slot.sh and check that testHistoryEditsAdvanceRevisionAndPreserveHealthKitLink
passes. That single test is the whole of §6 #1 and #5 evidence.
```

## 2026-08-13 — watch target made to compile again; first real gate in flight

Done: The branch never compiled the watch target. `9b43ad2` added
`namePlaceholderExercise` / `mergePlaceholderExercise` to `BurlyStore` and
left `FaultInjectingStore` (BurlyWatch/WatchDemoSeed.swift:424) behind, so
the gate died in `EmitSwiftModule` after 76s. Fixed in `ee57e15`: two plain
forwarding methods, no `Fault` case, matching `archiveExercise`. The green
check on PR #4 was package tests only — SwiftPM does not compile the watch
target and ci.yml:82 makes the sim job main-only.

Next: gate is queued second in `gate-chain.sh` (behind the m2-04 probe run).
On green, take PR #4 out of draft. The gate additionally asserts
`testHistoryEditsAdvanceRevisionAndPreserveHealthKitLink` actually appears
in a result bundle — §6 #1/#5 are unproven if it does not, even on a green
suite.

Resume:
```
Read /private/tmp/claude-501/-Users-dfakkeldy-Developer-health-apps/6797db06-aea3-4cdc-acde-97a45503f65e/scratchpad/gate-m5-03.log.
Worktree /Users/dfakkeldy/Developer/worktrees/burly-m5-03, branch task/burly-m5-03 at ee57e15.
If PRE-FLIGHT OK and the suite is green with the §6 test present, push and take PR #4 out of draft.
```
