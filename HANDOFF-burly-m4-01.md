# Burly M4-01 handoff

## Delivered

- Added `BurlySync` value DTOs for snapshot, session, and digest payloads.
- Added the JSON envelope `{ schemaVersion, kind, payload }`, schema version
  hold result, and typed malformed-input results.
- Added hostile-input and round-trip Swift Testing coverage, including every
  known newer-schema kind held before payload decode.
- Kept transport, protocol state, persistence mapping, and apply logic out of
  this change.

## Contract decisions

- Schema version 1 is the current supported version. A positive version above
  it is held; zero, negative, and older versions are malformed.
- Snapshot and digest snapshot versions are non-negative (`0` is accepted as
  an initial whole-working-set version).
- A session's minimal needs-naming exercise DTO carries only its UUID. Apply
  code in a later task reconstructs the fixed placeholder facts rather than
  accepting mutable name/origin/tag fields from the wire.
- Session-set weights use `BurlyCore.Weight`, retaining its finite,
  non-negative canonical-kg decode boundary. Digest entries reuse the existing
  `ExerciseLastPerformanceData` contract without duplication.

## Verification

- `cd BurlyKit && swift test` — passed: 377 tests in 40 suites.
- `cd BurlyKit && BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests`
  — attempted verbatim, blocked before test execution because the sandbox
  denies writes to Xcode's user clang module cache.
- Retried the migration command with `CLANG_MODULE_CACHE_PATH` redirected to
  `/private/tmp/burly-m4-01-clang-module-cache`; the toolchain then failed
  manifest compilation with `sandbox-exec: sandbox_apply: Operation not
  permitted`. No migration-spike result is claimed.
