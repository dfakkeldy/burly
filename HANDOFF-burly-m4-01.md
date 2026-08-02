# Burly M4-01 handoff

## Delivered

- Kept only the three `BurlySync` payload wrappers; their snapshot and session
  contents now reuse the cross-device `BurlyCore` `*Data` value types directly.
- Added the JSON envelope `{ schemaVersion, kind, payload }`, schema version
  hold result, and typed malformed-input results.
- Added hostile-input and round-trip Swift Testing coverage, including every
  known newer-schema kind held before payload decode.
- Kept transport, protocol state, persistence mapping, and apply logic out of
  this change.

## Contract decisions

- Schema version 1 is the current supported version. A positive version above
  it is held, zero and negative versions are malformed, and older versions
  without a registered decoder have their own typed malformed result. Future
  versions add a decoder/translation case; they never replace an older decoder
  with the hold path.
- Snapshot and digest snapshot versions are non-negative (`0` is accepted as
  an initial whole-working-set version).
- A session's `needsNamingExercises` are `ExerciseData` values: that existing
  cross-device type already carries the placeholder's `.custom` origin and
  `needsNaming` state, so no parallel identity DTO is needed.
- Session sets are `SetRecordData`, whose flat `weightKg` representation routes
  hostile values through `Weight(validatingKg:)`. Digest entries continue to
  reuse `ExerciseLastPerformanceData` without duplication.
- Sync decoding is deliberately stricter than domain `*Data` decoding: fields
  with a domain initializer default must still be present on the wire, so a
  truncated message cannot silently acquire a new meaning.

## Verification

- `cd BurlyKit && CLANG_MODULE_CACHE_PATH=/private/tmp/burly-m4-01-clang-module-cache swift test --disable-sandbox`
  — passed: 379 tests in 40 suites. The standard sandboxed invocation cannot
  compile the manifest here because this Codex sandbox denies the toolchain's
  `sandbox-exec` call.
- The migration-spike invocation is dispatcher-run; this sandbox cannot run
  its isolated manifest/process setup, so no migration-spike result is claimed.
