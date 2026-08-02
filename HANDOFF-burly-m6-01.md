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

## 2026-08-02 — Fix round 1: cross-engine adversarial review (7 majors, 4 minors, 1 nit), all closed

Done: every finding in `.scratch/m6-01-review-1.md` (verdict NOT-SAFE) is
fixed, each pinned by a new/rewritten test that fails on the pre-fix
behavior. Highlights: `ConsistencyStats.summarize` now takes the window's
`since` boundary so zero-session weeks count toward the "typical week"
denominator; `EpochBucketing` is replaced by `CalendarBucketing`, which
takes an explicit `Calendar` (time zone + firstWeekday) instead of a
hardcoded UTC epoch anchor, plus a `trailingWeekWindow` helper that aligns
named N-week ranges to exactly N buckets; `ExerciseProgressionStats`
quantizes Epley estimates to 0.01 kg before comparing (kills float-tie
false PRs), computes PRs over all-time history with a new
`displayRange` filter applied to the *output* (kills range-relative false
PRs), and `personalRecords` now sorts internally; `MuscleSplitStats`
returns a new `MuscleSplitSummary` with an explicit `unattributedFraction`
so zero-tag/unresolved sets never vanish from the denominator or fake a
"complete" split, and shares are normalized to literally sum to 1.0;
`VolumeStats` uses Kahan summation for order-independent totals;
`BurlyStore.loggedSetSlices`/`loggedSessionDates` now throw
`BurlyStoreError.unboundedStatsQuery` on an all-nil call (bound is
mandatory); the benchmark's RSS labeling and stale "Swift-side filter"
comment are corrected. Full finding→fix→test mapping is in this task's
final report. All call sites, tests, and the benchmark are updated
coherently (no external consumers exist yet — m6-02 hasn't started).

Verification, all green: `swift test` (417 tests / 46 suites),
`BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`
(2 tests), `BURLY_RUN_STATS_BENCHMARK=1 swift test --filter
StatsQueryBenchmarkTests` (fresh numbers: seed 3,600 sessions / 50,351
SetRecords in 98.2 s; trailing-90d query 0.113 s; one-exercise all-time
0.515 s / 4,306 slices — consistent with the 0.51 s this task's own doc
comments already cited; all-time session dates 0.137 s / 3,600 dates). No
schema change, no workflow change, no new dependencies.

Next: nothing outstanding for this fix round. Same follow-ups as before
apply (m8-02 device-floor re-benchmark; m6-02 is the first real consumer
of this layer).

Resume:
```
Fix round 1 is done and committed on task/burly-m6-01 in
~/Developer/worktrees/burly-m6-01. If a further review round comes back,
start from this task's final report (finding→fix→test mapping) and
`git log` on this branch before re-touching Sources/BurlyCore/Stats or
the BurlyStore stats-query methods.
```
