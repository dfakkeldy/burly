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
