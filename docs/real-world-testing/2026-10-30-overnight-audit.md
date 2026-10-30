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
| #17: imported workout titles disappear | Parser retains `SessionAccumulator.title` but omits `routineName`; History and detail fall back to “Workout” | Preserve the title without linking a routine or changing IDs | Parser and real-store regression passed in hosted package CI; visible-title UI assertions added, pending simulator |
| #18: History repeats whole-history work per row | Lazy row closure evaluates the computed `prSessionIDs` for every session | Capture the badge set once before building the list | Source confirms one projection per content evaluation; no measured speedup claimed |
| #18: badges omit estimated-1RM records and disagree on timestamp ties | Old badge loop compares only weight and sorts only by date | Reuse the core progression rules across exercises | New estimate-only, mixed-exercise, warmup/unattributed and equal-time regressions passed in hosted package CI |
| #19: consistency days do not announce dates | Every dot's accessibility label is only a workout status | Date label plus status value on each day | Accessibility-tree regression added; simulator result pending |
| #21: a failed set save discards the editor draft | The parent catches a write error, then the editor unconditionally dismisses | Return save success and dismiss only on success | Source path checked; app compilation and successful-edit acceptance pending; injected write failure not yet exercised |

## Coverage checkpoint

| Requested area | Reviewed so far | Status and next pass |
| --- | --- | --- |
| Bugs | Hevy parse/plan/commit flow; History badges; statistics and date projections | Five source-supported defects above; four issue records |
| Code | Import row validation/tokenizer and deterministic IDs; weight validation; History mutation and error paths; stats calculations | Package regressions pass for the first fixes. The editor's failed-write path now preserves its draft; runtime failure injection remains unverified |
| Performance | History list projection; Stats on-demand store queries; import detached parsing and main-actor planning | Repeated badge scan fixed. Profile large history/import plans and Stats reloads; source review alone does not establish latency or memory improvements |
| Architecture | Package target graph, store projections, importer boundary, phone/watch runtime placement, Health abstractions | Core remains UI-independent; import depends only on core; protocol machines and transport adapters are declared dependency-free. Badge policy duplication removed. Existing HealthKit and sync app-wiring PRs retain their scope; inspect their integration after merge |
| HIG/accessibility | Phone import scrolling, semantic typography/colors, chart labels, watch adjustable controls and rest controls | Date omission fixed. Inspect the Stats legend at large Dynamic Type and verify rendered/accessibility trees when simulators are available |
| Usability | Welcome/import/cancel/re-import/history flow; routine editor; history editor failure handling | Imported names restored; failed set saves retain their draft in source. Failure recovery and large-text navigation remain for runtime exercise; no physical-device behavior observed |

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
| Latest UI changes | Package/head CI and canonical phone/watch simulator acceptance pending |
| Delivery checkpoint | [PR #20](https://github.com/dfakkeldy/burly/pull/20) is draft; no merge or auto-merge is enabled while verification is outstanding |
| Main before this audit | Package job passed; simulator job failed in [40981119642](https://github.com/dfakkeldy/burly/actions/runs/40981119642). Existing simulator-discovery PR #16 also has a failed simulator gate |

Only synthetic fixture data is used. Physical-device testing and Instruments
traces have not been observed. Later checkpoints must report local tests,
hosted CI, PR readiness and merges separately.
