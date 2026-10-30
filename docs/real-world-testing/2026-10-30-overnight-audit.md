# Burly overnight audit — October 30, 2026

Run started at 00:03 ADT (03:03 UTC), from `829fe5d` on `origin/main`.
There is no `nightly` branch. The clean audit branch is
`codex/overnight-audit-20261030-cycle-1`.

This is an ongoing audit, not an exhaustive pass or a release sign-off.
Work ends by 08:00 ADT, or after the bug-hunt workflow's 60 active search
minutes without a new reproducible bug. Setup, implementation, builds and
CI waits do not count toward that quiet hour. No quiet hour has been
established at this checkpoint.

## Findings and fixes

| Finding | Evidence | Change | Verification |
| --- | --- | --- | --- |
| #17: imported workout titles disappear | Parser retains `SessionAccumulator.title` but omits `routineName`; History and detail fall back to “Workout” | Preserve the title without linking a routine or changing IDs | Parser, real-store and visible-title UI regressions passed in hosted CI at `a453627` |
| #18: History repeats whole-history work per row | Lazy row closure evaluates the computed `prSessionIDs` for every session | Capture the badge set once before building the list | Source confirms one projection per content evaluation; no measured speedup claimed |
| #18: badges omit estimated-1RM records and disagree on timestamp ties | Old badge loop compares only weight and sorts only by date | Reuse the core progression rules across exercises | New estimate-only, mixed-exercise, warmup/unattributed and equal-time regressions passed in hosted package CI |
| #19: consistency days do not announce dates | Every dot's accessibility label is only a workout status | Date label plus status value on each day | 28 distinct date labels and both status values passed the accessibility-tree regression at `a453627` |
| #21: a failed set save discards the editor draft | The parent catches a write error, then the editor unconditionally dismisses | Return save success and dismiss only on success | Synthetic first-write rejection and retry UI coverage added; runtime result pending |
| #22: archiving an exercise hides its historical name | History loads only active exercise metadata; detail resolves names from that array | Include archived metadata in History; exclude it from selection and naming work | Catalog archive → History name/sets/revision → Add Exercise exclusion regression added; runtime result pending |
| #23: all-time progression query costs 8.2453 s at 50k sets | Existing hosted scale benchmark; all SetRecords fetched before exercise filtering | Bounded inverse traversal being measured separately | Baseline reproduced; candidate not yet adopted |
| #24: digest costs 6.1419 s at 50k sets | Existing hosted benchmark exceeds its 3 s signal threshold | Separate performance follow-up | Baseline reproduced; no fix or device timing claimed |
| #25: progression renders one blue zigzag instead of two trends | Successful simulator's `BurlyPhone-statsPounds` screenshot shows connections between top set and e1RM within each session | Explicit series identities and categorical colors for both trends and PRs | Fix and legend assertions pushed; fresh rendered screenshot pending |
| #26: Stats has no navigation title and content overlaps status time when scrolled | `BurlyPhone-statsPounds` and `BurlyPhone-consistencyDates` screenshots; Stats alone lacks a NavigationStack | Restore a tab-owned navigation host | Navigation-bar regression and fresh screenshots pending |

## Coverage checkpoint

| Requested area | Reviewed so far | Status and next pass |
| --- | --- | --- |
| Bugs | Hevy parse/plan/commit flow; History badges; statistics/date projections; archive-to-History flow; scale benchmarks; rendered charts/navigation | Ten source/benchmark/screenshot-supported defects above; nine issue records |
| Code | Import row validation/tokenizer and deterministic IDs; weight validation; History mutation and error paths; stats calculations | Package regressions pass for the first fixes. The editor's failed-write path now preserves its draft; runtime failure injection remains unverified |
| Performance | History list projection; Stats store queries; import detached parsing/main-actor planning; existing 50k-row stats/digest benchmarks | Repeated badge scan fixed in source; baseline query/digest costs measured below. Candidate optimization remains separate until equivalence and before/after measurements pass |
| Architecture | Package target graph, store projections, importer boundary, phone/watch runtime placement, Health abstractions | Core remains UI-independent; import depends only on core; protocol machines and transport adapters are declared dependency-free. Badge policy duplication removed; historical metadata now includes archives while selection surfaces filter them. Existing HealthKit and sync app-wiring PRs retain their scope; inspect their integration after merge |
| HIG/accessibility | Phone import scrolling, semantic typography/colors, chart labels, watch adjustable controls/rest controls, exported phone/watch screenshots | Date accessibility verified at `a453627`; rendered chart grouping and missing navigation host reproduced and fixed in source. Fresh screenshots and largest Dynamic Type remain unverified |
| Usability | Welcome/import/cancel/re-import/history flow; routine editor; history editor failure handling; default watch viewport | Imported names verified. Failed-save retry/archive flows await new-head CI. Default watch screenshot places Log set below the initial viewport; scroll/layout ergonomics remain an observed follow-up in the separately owned watch flow |

Apple references: [Charts](https://developer.apple.com/design/human-interface-guidelines/charts),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout).

## Verification log

| Check | Result |
| --- | --- |
| Repository state / current ownership | Clean main isolated into an audit worktree; active HealthKit, sync and simulator-discovery changes left with their owners |
| `git diff --check` after edits | Passed |
| Local package test attempts through the shared build-slot wrapper | Deferred (exit 75): first memory/swap admission, later another build holding the slot; tests did not run |
| Hosted package run [40995968096](https://github.com/dfakkeldy/burly/actions/runs/40995968096), head `677d5cd` | Passed: 826 tests in 83 suites, plus 2 migration-spike tests in a separate process |
| Hosted checks [40996708680](https://github.com/dfakkeldy/burly/actions/runs/40996708680) / [40996703036](https://github.com/dfakkeldy/burly/actions/runs/40996703036), head `a453627` | Both package jobs passed; canonical simulator gate passed phone 17/17 and watch 27/27 at 01:14 ADT |
| Later archive fix and first-save-failure regression | Prepared commits now being pushed for their own package/simulator verification; the earlier green head does not verify these additions |
| Delivery checkpoint | [PR #20](https://github.com/dfakkeldy/burly/pull/20) is draft; no merge or auto-merge is enabled while verification is outstanding |
| Main before this audit | Package job passed; simulator job failed in [40981119642](https://github.com/dfakkeldy/burly/actions/runs/40981119642). Existing simulator-discovery PR #16 also has a failed simulator gate |
| Existing PR #16, [40985962460 attempt 1](https://github.com/dfakkeldy/burly/actions/runs/40985962460/attempts/1) | Phone 16/16 passed; watch 26/27 passed, failing `testLateActiveSessionRaceReachesSessionConflictViewAndDiscardResolvesIt` at its conflict-heading assertion. Attempt 2 is running under the existing owner; no test bypass or takeover |

At 00:43 ADT the archive-name defect reset the quiet-search counter.
Approximately two active search minutes followed before this checkpoint;
implementation and CI inspection are excluded. The local save-failure test
and archive fix are committed and held until the already-running simulator
gate produces evidence, avoiding cancellation of that run mid-suite.

The store's all-time single-exercise query still fetches all SetRecords and
filters by exercise in Swift, as its implementation and existing gated
50k-row benchmark document. The older integration helper's description of
that query as SQL-pushed-down is stale. A fresh measurement and possible
exercise-inverse relationship traversal are follow-up audit work; no
latency, memory or improvement figure is inferred from the source alone.

## Performance baseline, hosted Xcode 26.6 Debug

The existing benchmarks ran on main `829fe5d` via diagnostic `fe4188c`
([run 41001270610](https://github.com/dfakkeldy/burly/actions/runs/41001270610)).
Only their two existing enable flags changed; no app or pipeline code did.
The fixture held 3,600 sessions, 50,351 sets and 12 exercises.

| Operation | Output | Wall time |
| --- | --- | --- |
| All-exercise trailing 90-day sets | 1,173 slices | 0.2349 s |
| One-exercise all-time sets | 4,306 slices | 8.2453 s |
| All logged session dates | 3,600 dates | 0.2617 s |
| Latest-performance digest | 12 exercise entries | 6.1419 s |

Both existing large-fixture seeds took about 157 s. Process high-water RSS
was 1,130.0 MB after the first seed and 2,330.8 MB after the second seed and
surrounding suite. These peaks include test/seeding allocations, are not
per-query measurements, and do not establish shipping-app or device memory.
The diagnostic suite passed 822 tests plus two separate migration tests;
its benchmark threshold warnings are signals, not CI failures.

## Rendered review checkpoint

The successful `a453627` simulator artifact was downloaded and inspected.
`BurlyPhone-statsPounds` exposed #25 and the missing Stats heading;
`BurlyPhone-consistencyDates` exposed status-bar overlap. Its accessibility
test nevertheless passed: correct labels and passing numeric assertions
did not establish that the plotted paths or navigation chrome were correct.
The next UI run includes a dedicated `BurlyPhone-progressionSeries` capture.

Default watch logging/summary captures were also inspected. Their text and
controls use the expected hierarchy, but Log set is below the initial
logging viewport and summary actions require scrolling. The active watch
session work is kept separate; this is a usability observation, not a
claim of a failed button or observed physical-device ergonomics. These
captures show pounds; watch unit synchronization remains the separate
integration task rather than a new duplicate audit ticket.

Only synthetic fixture data is used. Physical-device testing and Instruments
traces have not been observed. Later checkpoints must report local tests,
hosted CI, PR readiness and merges separately.
