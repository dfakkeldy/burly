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

## 2026-08-02 — Fix round 2: re-review (4 of 5 accepted findings, 1 overruled), all closed

Done: every accepted finding in `.scratch/m6-01-review-2.md` fixed, each
pinned by a new test failing on the pre-fix behavior. Item 1 (typical-week
denominator) was OVERRULED by the dispatcher — untouched, including its
pinning test. Highlights: `ExerciseProgressionStats` e1RM tie detection
replaced 0.01 kg absolute quantization with a `1e-9` *relative* epsilon
(`isGenuineEstimateImprovement`) — kills the 1.22e-16-relative float-noise
tie (87.5×10 vs. 100×5, still pinned) while registering the reviewer's
3.4e-4-relative genuine improvement (46 lb×2 → 47.5 lb×1, now a real e1RM
PR) — twelve orders of magnitude separate the two cases, so `1e-9` has six
decades of headroom on both sides. `BurlyStore`'s query surface reshaped so
the bound is enforced by API *shape*, not a runtime nil-check that a
sentinel like `.distantPast` could satisfy: `loggedSetSlices` split into
`loggedSetSlices(exerciseID: UUID, since:through:)` (exercise-bounded,
`since: nil` legal — the PR chart's "all" range) and
`loggedSetSlices(window: TrailingWindow, through:calendar:)` (all
exercises, only a validated `TrailingWindow` — new domain type,
`.days`/`.weeks`, positive, capped at 400 days — no arbitrary `Date` at
all); `loggedSessionDates(since: Date, through:)` now takes a non-optional
`since`, and the genuinely-unbounded case is its own named method,
`allLoggedSessionDates()`, documented as an exempt flat O(sessions)
projection (0.126 s / 3,600 dates at 50k SetRecords, no relationship
prefetch). `BurlyStoreError.unboundedStatsQuery` removed — no remaining
call can express an unbounded query, so there is nothing left to throw for.
Added `BurlyStore.exerciseProgression(exerciseID:displayRange:)` — the
blessed integration path that always fetches all-time via the exercise-
bounded query before computing PRs, closing the previously-unenforceable
all-time precondition on `personalRecords` (pure BurlyCore has no store to
enforce it itself). `VolumeStats.weeklyVolume` and `MuscleSplitStats
.fractionalSplit` both sort slices by `(completedAt, set.id)`
(`sortedForDeterministicSummation()`) before accumulating — Kahan is
accurate but not order-*independent*, so determinism now comes from the
sort, precision from Kahan on top of it; pinned by a 5-seed shuffled-input
test asserting bit-identical totals. Added a DST spring-forward test
(`CalendarBucketingTests`) proving a 167-hour week still buckets as one
week and sessions either side of the 2026-03-08 transition land in the
same day/week. No schema change, no workflow change, no new dependencies;
all tests/benchmark/docs updated coherently for the API reshape (m6-02
still hasn't started — no external consumers to migrate).

Verification, all green: `swift test` (428 tests / 48 suites, run 3× to
rule out flakiness from the now-random-UUID sort tie-breaks — none),
`BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests` (2
tests), `BURLY_RUN_STATS_BENCHMARK=1 swift test --filter
StatsQueryBenchmarkTests` (fresh numbers: seed 3,600 sessions / 50,351
SetRecords in 94.71 s; `loggedSetSlices(window: .days(90))` 0.0835 s /
1,173 slices; `loggedSetSlices(exerciseID:, since: nil)` 0.4759 s / 4,306
slices; `allLoggedSessionDates()` 0.1258 s / 3,600 dates — all consistent
with round 1's numbers).

One explicit deviation from the brief: the suggested integration-path
signature was `exerciseProgression(exerciseID:displayRange:calendar:)`;
the shipped signature omits `calendar:` because `ExerciseProgressionStats`
has no calendar dependency at all (Epley/PR computation is calendar-free) —
an unused parameter would be pure API noise. `VolumeStats`/`ConsistencyStats`
are the ones that need a calendar, and `loggedSetSlices(window:through:
calendar:)` already carries one for them.

Next: nothing outstanding for this fix round. Same follow-ups as before
(m8-02 device-floor re-benchmark; m6-02 is the first real consumer of this
reshaped layer — its `loggedSetSlices`/`loggedSessionDates` call sites
should read this round's `BurlyStore` doc comments before writing new ones).

Resume:
```
Fix round 2 is done and committed on task/burly-m6-01 in
~/Developer/worktrees/burly-m6-01. If a further review round comes back,
start from this task's final report (finding→fix→test mapping) and
`git log` on this branch before re-touching Sources/BurlyCore/Stats or
the BurlyStore stats-query methods. Re-review item 1 (typical-week
denominator) is OVERRULED and pinned as-is — do not re-litigate it without
a new dispatcher decision.
```
