# Handoff — burly-m6-01 (Stats computations + fixture-truth tests)

## 2026-08-01 — Task complete: stats layer, bounded queries, benchmark, all green

Done: BurlyCore `Stats/` (SetRecordSlice, EpochBucketing,
ExerciseProgressionStats/Epley+PRs, VolumeStats, MuscleSplitStats,
ConsistencyStats) with 18 fixture-truth tests. BurlyPersistence
`BurlyStore.loggedSetSlices`/`loggedSessionDates` — bounded by a `Date`
predicate, `.logged`-state filtered, `SetRecordSlice`-shaped (never the
full session graph) — closing the m1-06 binding requirement. Pushed
`exerciseID` into the SQL predicate after the first benchmark run showed
the all-time single-exercise query at 4.04 s / 172 MB on 50k rows;
after, 0.51 s / 40 MB for the identical result (measured, not estimated).
50k-SetRecord benchmark added, gated by `BURLY_RUN_STATS_BENCHMARK=1`,
mirroring `MigrationSpikeTests`'s gate. 7 persistence-level tests cover
date bounds, exercise scoping, `.active`-session exclusion, and §7
acceptance #2 (hevyImport parity). Both required invocations green:
`swift test` (393 tests/45 suites) and
`BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`
(2 tests). No schema change, no workflow change, no new dependencies.

Next: nothing outstanding for m6-01. Task m8-02 (device-floor check) will
run `BURLY_RUN_STATS_BENCHMARK=1 swift test --filter
StatsQueryBenchmarkTests` on real device hardware and compare against the
Mac numbers recorded in the dispatcher's final report / PR description —
Mac timing here is informational, not the acceptance gate. Whoever builds
the phone-side chart UI (later M6/M7 task) is the first real consumer of
`BurlyStore.loggedSetSlices`/`loggedSessionDates` plus the `*Stats`
functions; nothing in this task assumes a particular chart library or
range-picker UI beyond the spec's named ranges.

Resume:
```
This task is done — nothing to resume. If re-opening burly-m6-01 for a
follow-up, the worktree is
~/Developer/worktrees/burly-m6-01 (branch task/burly-m6-01). Start by
reading this file's "Spec ambiguities interpreted" note in the task's
final report (or `git log -1` for the commit message) before touching
Sources/BurlyCore/Stats or the two new BurlyStore query methods.
```
