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
