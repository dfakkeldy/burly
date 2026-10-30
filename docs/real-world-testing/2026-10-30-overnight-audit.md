# Burly overnight audit — October 30, 2026

Checkpoint while the overnight audit continues. Started 00:03 ADT from
`829fe5d` on `origin/main`; there is no nightly branch. The hard stop is
08:00 ADT / 11:00 UTC. This is evidence from the exercised flows, not an
exhaustive audit or release sign-off.

Thirteen confirmed defects are tracked under twelve issues. Nine are
merged; three focused fixes are undergoing native verification; the
remaining digest performance defect has a separate implementation plan.
All fixtures are synthetic.

## Findings and delivery

| Finding | Reproduction / cause | Fix and status |
| --- | --- | --- |
| [#17](https://github.com/dfakkeldy/burly/issues/17): imported titles disappear | Parser retained the accumulated title but omitted `routineName`; History fell back to “Workout” | Preserve title without routine linkage or changed IDs. Merged #20; parser, real-store and visible-title regressions passed. |
| [#18](https://github.com/dfakkeldy/burly/issues/18): per-row History work | Each row evaluated a whole-history PR projection | Capture once per list render. Merged #20; source-backed reduction, no measured frame-rate claim. |
| #18: incorrect PR badges | Weight-only comparison omitted e1RM records; timestamp ties lacked the core ordering policy | Share core progression policy. Merged #20; estimate-only, mixed-exercise, warmup/unattributed and tie regressions passed. |
| [#19](https://github.com/dfakkeldy/burly/issues/19): calendar dates absent from accessibility | Day dots announced workout status without their date | Full local date plus status value. Merged #20; 28 distinct dates and both statuses verified in the accessibility tree. |
| [#21](https://github.com/dfakkeldy/burly/issues/21): failed save loses draft | Editor dismissed after a caught write failure; a parent alert could not present over the pushed editor | Throw to the active editor's own catch/alert; dismiss only on success. Merged #20; injected first failure, visible error, retained draft and single successful retry passed. |
| [#22](https://github.com/dfakkeldy/burly/issues/22): archived names lost from History | History metadata excluded archived exercises | Include historical metadata while keeping selection/naming surfaces filtered. Merged #20; archive → History name/sets/revision → picker exclusion passed. |
| [#23](https://github.com/dfakkeldy/burly/issues/23): slow all-time progression | Single-exercise reads materialized every set before filtering | Exercise inverse traversal for the unbounded single-exercise path. Merged #28; same 4,306 slices, cold reopen/archive/active-session and primed-cache merge checks passed. |
| [#24](https://github.com/dfakkeldy/burly/issues/24): slow latest-performance digest | Full-history materialization dominates pure derivation at 50k sets | Open. Rejected a non-improving prefetch variant; narrower projection is experimental, not integrated. |
| [#25](https://github.com/dfakkeldy/burly/issues/25): one zigzag instead of separate trends | Rendered artifact connected top-set and e1RM points within each session | Explicit series/colors, with ordinary adaptive legend outside Charts' synthesized tree. Merged #20; fresh rendering and legend assertions passed. |
| [#26](https://github.com/dfakkeldy/burly/issues/26): missing Stats navigation host | Title absent and content under status chrome in rendered artifact | NavigationStack around Stats. Merged #20; title and scroll-edge rendering inspected. |
| [#30](https://github.com/dfakkeldy/burly/issues/30): largest-text Stats clipping | Selected title clipped; fixed-height axes overlapped or ellipsized | Draft #31: wrapping selector, scaled plot, sparse endpoint dates. Local iOS27 targeted test and full title/date-axis captures passed; hosted gate pending after discovery-only failure. |
| [#32](https://github.com/dfakkeldy/burly/issues/32): Stats stale after activation | Pre-fix native test independently found new History data while Stats stayed at the old count with 6M retained | Draft #29: refresh only requested, visible Stats using its last request. Fixed-head local and hosted regression passed; full hosted suite pending after retained Settings unit-selection timeout. |
| [#34](https://github.com/dfakkeldy/burly/issues/34): Hevy action ellipsis | Largest-text pre-audit capture shows “Import 3 Workou…” | Draft #35: full-width wrapping title at accessibility sizes. Repair/native verification pending; no completed fix claimed yet. |

## Coverage of the six requested areas

| Area | Evidence / conclusion | Limits or next work |
| --- | --- | --- |
| Bugs | Import/re-import, archive/history/picker, failed-save/retry, Stats lifecycle, unit rendering and chart flows exercised | Findings above are distinct from incomplete features and harness failures. |
| Code | Import parse/plan, strict persistence reads, numeric input, history mutations, snapshot metadata and shared stats policy inspected | No broad cleanup, schema migration or public API change shipped. |
| Performance | Per-row derived work removed; 50,351-set query benchmark and digest phase measurements collected | Debug fixture cost is not a physical-device, energy or frame-rate measurement. |
| Architecture | Core/persistence/runtime boundaries reviewed; historical metadata separated from selection; badge policy duplication removed | Digest needs a narrower supported read contract with strict failure semantics and one shared selection policy. |
| HIG/accessibility | Phone/watch rendering, date semantics, chart series/legend/navigation, largest text and native accessibility audits inspected | A passing audit at a scrolled viewport did not establish whole-screen compliance; rendered inspection found #30/#34. |
| Usability | Imported names, partial/error recovery, archive continuity, retained ranges and reachable import confirmation exercised | Watch Log set starts below the initial viewport in captured layout. This is an observation within separate watch work, not a failed button or observed device ergonomics. |

The existing HealthKit, sync, simulator/test hardening and privacy-readiness
PRs remain separate. This audit does not establish completion of those
features or physical-device acceptance.

## Verification and exact delivered heads

| Delivery / run | Result |
| --- | --- |
| [#20](https://github.com/dfakkeldy/burly/pull/20), tested `a548cf5`; [41010129851](https://github.com/dfakkeldy/burly/actions/runs/41010129851) | 826 package + 2 migration tests; phone 19/19; watch 27/27. Fresh title/series/legend, retry/revision and archived-history artifacts reviewed. Merged `7149531`. |
| [#28](https://github.com/dfakkeldy/burly/pull/28), tested `481ecf3`; [41016575153](https://github.com/dfakkeldy/burly/actions/runs/41016575153) | 828 package + 2 migration tests; phone 19/19; watch 27/27. Merged `e5b858e`. Benchmarks retain normal environment gates. |
| [#29](https://github.com/dfakkeldy/burly/pull/29), `43b3a94`; [41031247128](https://github.com/dfakkeldy/burly/actions/runs/41031247128) | Package checks passed. New foreground regression passed locally on iOS27 (37.867s) and hosted (45.618s). First full run phone 19/20: retained Settings unit-selection wait failed; watch not reached. One unchanged full-gate retry runs. |
| [#31](https://github.com/dfakkeldy/burly/pull/31), `8588a22`; [41033532615](https://github.com/dfakkeldy/burly/actions/runs/41033532615) | Package checks passed. Targeted iOS27 regression passed, including date axes above the tab bar; rendered title/axes inspected. Hosted attempt1 stopped before app tests at destination discovery; unchanged retry runs. |
| [#35](https://github.com/dfakkeldy/burly/pull/35), `4772b2f` | Draft repair. Initial Label title repair remained constrained; an invalid three-line height expectation was replaced with clipping and completed-import checks. Current local/hosted result pending. |

Local Apple builds/tests used the shared slot wrapper. Earlier attempts
were deferred on admission; admitted commands used only a dedicated
synthetic phone simulator and shut it down afterwards. Existing simulators
and unrelated processes were preserved. No physical-device testing or
additional deployment was performed.

## Performance evidence

Hosted Xcode 26.6 Debug fixture: 3,600 sessions, 50,351 sets, 12 exercises.

| Operation | Output | Time |
| --- | --- | --- |
| All-exercise trailing 90-day query | 1,173 slices | 0.2349s |
| Baseline all-time single-exercise query | 4,306 slices | 8.2453s |
| Exercise inverse candidate | Same 4,306 slices | 1.6870s |
| All logged session dates | 3,600 dates | 0.2617s |
| Baseline digest | 12 entries | 6.1419s |

[Baseline](https://github.com/dfakkeldy/burly/actions/runs/41001270610)
and [inverse candidate](https://github.com/dfakkeldy/burly/actions/runs/41004588146)
ran separately: about 4.9× lower observed query time, without a device-speedup
claim. The delivered query has cold persisted-store and live inverse-cache
regressions; date-bounded queries retain their existing path.

Digest [phase profiling](https://github.com/dfakkeldy/burly/actions/runs/41006812710)
measured 8.4439s total, a separate fresh-context fetch 8.4568s, and pure
derivation 0.0690s for the same 12 entries. A parent-only-prefetch variant
preserved output but total 9.6150s did not improve, so it was rejected.

A [diagnostic projection](https://github.com/dfakkeldy/burly/actions/runs/41020233505)
returned 74 candidate slices / the same 12 entries in 1.6164s versus 8.3665s full
generation in that run. It is feasibility evidence only. Before adoption:
share latest-session/tie policy, define strict read/error behavior, test
empty/latest-empty/tie/repeated/nil/active/archive/corrupt cases and validate
against native persisted SQLite. No prototype API or runtime wiring shipped.
Process high-water RSS included seeding/the full suite and is not an app or
per-query memory measurement.

## Native HIG diagnostic classification

[Diagnostic #27](https://github.com/dfakkeldy/burly/pull/27) closed without
integration. First attempts failed at simulator discovery before app tests.
The next Hevy attempt failed a pre-scroll harness existence assertion.
The corrected [run 41029041077](https://github.com/dfakkeldy/burly/actions/runs/41029041077)
reached phone 20/21. Largest-category proof and Stats' legend-viewport native
Dynamic Type/text-clipping audit passed. Manual top captures still exposed
#30. Hevy confirmation was reachable; its pre-audit image exposed #34.

The native Dynamic Type failure's element attachment is the system Cancel
toolbar control, with a generic SwiftUI.AccessibilityNode description. It
is not counted as another app defect and no app workaround is adopted for
it. The diagnostic's temporary 900s discovery window and diagnostic-only
tests are never for integration.

Apple references: [Charts](https://developer.apple.com/design/human-interface-guidelines/charts),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[native audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app).

## Time and stopping rule

The wall-clock night window is distinct from active searching. Setup,
implementation, builds, CI/service waits and artifact verification pause
the quiet-search timer. Checkpoints retain approximate search counts;
concurrent CI durations are not added as searching time.

New findings reset the counter around 05:47/06:00 ADT and again at 06:51 for
#34. The 06:16–06:30 interval was roughly 14 verification/CI minutes and zero
quiet-search minutes; approximately 3 minutes of visual/source
classification in 06:46–06:52 found #34. No 60-minute active quiet period has
been established. Final results and the morning stop remain to be recorded.
