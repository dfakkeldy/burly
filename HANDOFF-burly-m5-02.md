# Burly m5-02 handoff — routine builder and catalog browser

## Delivered

- Replaced the Routines placeholder with a user-ordered routine list, create
  form, whole-routine editor, list/item reordering, per-item set counts and
  rest overrides, save, and archive confirmation.
- Added an on-demand searchable catalog browser with the bundled curated
  catalog, custom exercise creation, all 12 `MuscleGroup` tags, and archive.
- Kept writes in `PhoneHomeViewModel` on `@MainActor`: it validates names and
  tags, normalizes item order, performs caller-owned routine-list reindexing,
  and invokes only the existing `BurlyStore` authoring/archive surfaces.
- Made the UI-test `empty` scenario seed the real catalog while retaining no
  user routines or logged history. Added stable UUID-qualified row/control
  identifiers and a new end-to-end XCTest for §9 #3's routine/custom flow.

## Changed files

- `BurlyPhone/RoutinesTabView.swift`
- `BurlyPhone/PhoneHomeViewModel.swift`
- `BurlyPhone/PhoneDemoSeed.swift`
- `BurlyPhoneUITests/BurlyPhoneUITests.swift`

## Verification

- `cd BurlyKit && CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m5-02-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/burly-m5-02-swiftpm-cache swift test --disable-sandbox`
  - Passed: 732 Swift Testing tests in 77 suites.
- `cd BurlyKit && BURLY_RUN_MIGRATION_SPIKE=1 CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m5-02-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/burly-m5-02-swiftpm-cache swift test --disable-sandbox --filter MigrationSpikeTests`
  - Passed: 2 migration-spike tests.
- A real `xcodebuild build -project Burly.xcodeproj -scheme BurlyPhone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` completed successfully after the primary phone UI implementation.
- A later repeat app build, after the final search/fixture edits, could not
  start package resolution in this sandbox because Xcode was denied write
  access to `/Users/dfakkeldy/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/burlykit.dia`; it did not report source diagnostics.
- `Scripts/acceptance-sim.sh` was run twice, the maximum allowed:
  1. default lock path was outside this sandbox's writable roots;
  2. with the script-supported `BURLY_LOCK_DIR=/private/tmp/burly-m5-02-sim.lock`, lock acquisition succeeded but `xcrun simctl list devices --json` failed before any build/test because CoreSimulatorService was unavailable.

## Remaining gate

The new phone UI XCTest has not run on a simulator in this sandbox. Re-run the
canonical acceptance script in an environment that can access the named shared
simulator pair and the normal SwiftPM manifest cache; do not treat either
environment failure above as an application-test result.

## 2026-08-02 — acceptance-sim run: one bug fixed, one found, still red

Done: Line-295 failure was a TEST bug — the alphabetically-sorted ~100-row
catalog List only materializes on-screen rows, so a "U"-named custom exercise
never entered the viewport for `waitForExistence`. Fixed by searching for the
new name first (mirrors the existing archive-step pattern), commit b2a8c60.
Live `Scripts/acceptance-sim.sh` run (1 of 2 allowed) confirms this clears
line 295, then fails one step later: `catalog.doneButton` is unreachable
while the search field/keyboard has focus. The SAME run's failure dump also
shows a distinct, unfixed bug: `CatalogBrowserView` row children's own
`.accessibilityIdentifier()` (`catalog.archiveExercise.*`, and presumably
`catalog.addExercise.*`/`catalog.exerciseName.*`) all collapse to the row's
own `catalog.exerciseRow.*` identifier on every row. BurlyKit `swift test`
(732) and `MigrationSpikeTests` (2/2) still green. Overall suite: NOT green.

Next: (1) dismiss the search field (Cancel / resign first responder) before
tapping `catalog.doneButton`; (2) fix the CatalogBrowserView identifier
collapse so `catalog.addExercise.*`/`catalog.archiveExercise.*` are reachable
— needed for this same test's later add-exercise (~line 312) and archive
(~line 361) steps. Re-run `Scripts/acceptance-sim.sh` once both land.

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m5-02-codex
git log --oneline -3  # confirm HEAD includes b2a8c60 on task/burly-m5-02
# 1. BurlyPhoneUITests.swift ~line 309: dismiss search before tapping catalog.doneButton
# 2. BurlyPhone/RoutinesTabView.swift CatalogBrowserView row: fix identifier collapse
# 3. Scripts/acceptance-sim.sh (fresh run budget)
```
