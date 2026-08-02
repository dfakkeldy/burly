# Handoff — burly-m6-02

## Delivered

- Replaced the phone Stats placeholder with four Swift Charts cards:
  progression/PRs, weekly volume, fractional muscle split, and consistency.
- Added 3M/6M/1Y/all progression ranges and 8W/26W/52W volume ranges.
- Added a deterministic populated phone UI-test scenario spanning 50 weeks,
  including an optional-exercise working set so unattributed muscle work is
  visibly retained rather than renormalized away.
- Added stable data/empty leaf identifiers and XCUITest coverage for all four
  chart branches.

## Stats data contract

`PhoneHomeViewModel.loadStats` is `@MainActor` and is the only phone chart
store access path. It uses:

- `BurlyStore.exerciseProgression(exerciseID:displayRange:)` for all-time PR
  correctness before display filtering;
- `loggedSetSlices(window:through:calendar:)` with `TrailingWindow` for 8/26/52
  week volume and 4-week muscle split;
- `loggedSessionDates(since:through:)` for 8-week consistency.

Views receive `BurlyCore` results and format/chart them only. No view calls
`sessions()` or recomputes PR, volume, muscle, or consistency statistics.
Weeks use `Calendar.autoupdatingCurrent` and the UI states that week boundaries
follow the user’s time zone and first-day-of-week setting.

## Verification

Passed in this sandbox (the cache redirect and `--disable-sandbox` are local
sandbox workarounds, not repository/CI changes):

```sh
cd BurlyKit
CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m6-02-clang-module-cache swift build --disable-sandbox
CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m6-02-clang-module-cache swift test --disable-sandbox
BURLY_RUN_MIGRATION_SPIKE=1 CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m6-02-clang-module-cache swift test --disable-sandbox --filter MigrationSpikeTests
```

- `swift test`: 732 tests passed (benchmark/migration-only suites skipped as
  designed by their environment gates).
- `MigrationSpikeTests`: 2 tests passed.
- `swiftc -parse` passed for the changed phone and UI-test sources.

Not verified here:

- `Scripts/acceptance-sim.sh` was invoked once but exited before any build or
  simulator action because the sandbox denied creating its required global lock
  at `/Users/dfakkeldy/Developer/health-apps/plan/dispatch/sim.lock`. Do not
  redirect that lock in a shared host; rerun the exact script in the normal
  developer environment to execute the iPhone chart UI tests.
- A generic-device `xcodebuild build` also cannot resolve the local package in
  this sandbox because Xcode’s manifest/module cache lives under inaccessible
  user cache directories. This is environment-only and occurred before app
  source compilation.

## Files changed

- `BurlyPhone/PhoneHomeViewModel.swift`
- `BurlyPhone/StatsTabView.swift`
- `BurlyPhone/PhoneDemoSeed.swift`
- `BurlyPhoneUITests/BurlyPhoneUITests.swift`

## Follow-up gate

Run `Scripts/acceptance-sim.sh` once in an environment that can acquire the
shared lock, then inspect the resulting `BurlyPhoneUITests` report for the
populated and empty Stats scenarios. No code ambiguity remains; the only open
item is that host-level simulator acceptance receipt.
