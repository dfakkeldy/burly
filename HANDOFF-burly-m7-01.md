# HANDOFF — burly-m7-01

## 2026-08-01 — Hevy CSV parser + mapping + deterministic UUIDs + dropped-data accounting complete

Done:
- New `BurlyImport` SPM target/product in `BurlyKit/` (BurlyCore-only
  dependency; no BurlyPersistence, keeping the persistence-wiring seam
  clean for a later M7 task). Files: `CSVTokenizer.swift` (hand-rolled
  RFC-4180-ish tokenizer, scans `unicodeScalars` not `Character` —
  Swift's grapheme clustering merges `"\r\n"` into one `Character`, which
  silently broke CRLF handling until switched), `HevyCSVSchema.swift`
  (header-driven column resolution), `HevyTimestamp.swift` (hand-parses
  both `yyyy-MM-dd HH:mm:ss` and real Hevy's `d MMM yyyy, HH:mm`, avoiding
  non-`Sendable` `DateFormatter` under Swift 6 strict concurrency),
  `DeterministicUUID.swift` (RFC 4122 UUIDv5 via CryptoKit SHA-1, system
  framework not a dependency), `HevyRowDecoding.swift` (per-row validation
  + session/item accumulators), `HevyCSVImporter.swift` (orchestration),
  `HevyImportTypes.swift` (public result/summary/error types). Tests in
  `BurlyKit/Tests/BurlyImportTests/` (50 tests).
- `CatalogSeed.exerciseID(forHevyAlias:)`/`exercise(forHevyAlias:)` now
  case-insensitive (carried-forward finding from m1-05 review) — added
  `normalizedHevyAliases`, precomputed once at construction, plus a test.
  Added a doc comment at the "Pullover (Cable)" alias flagging it for
  m7-03 re-verification (left the mapping itself unchanged, per
  instructions).
- Real-world Hevy CSV column shape researched (public sample export +
  docs, no real health data): `title,start_time,end_time,description,
  exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,
  reps,distance_km,duration_seconds,rpe`. The importer is header-driven
  (resolves columns by name, not position) so it already handles this
  fuller shape as well as `BurlyFixtures.HevyCSVGenerator`'s minimal
  8-column shape — no fixture-generator changes needed; cardio/RPE/
  superset/failure-dropset test scenarios use hand-written CSV text
  against the fuller header since the shared generator doesn't model
  those columns.
- **Real bug found and fixed during this task**: Swift `Dictionary`
  iteration order is NOT stable even across two identically-constructed
  dictionaries within the same process (empirically confirmed — same
  keys, same insertion order, two separate `[String: Int]` builds in one
  `swift` script run produced different `Array(dict.keys)` each time).
  `HevyCSVImporter` was building `newExercises` via
  `Array(newExercisesByName.values)`, which broke the "same file
  re-imported → identical result" guarantee — caught by the
  `sameFileReimportedProducesIdenticalResult` test. Fixed by tracking
  first-appearance order in a separate `[String]` array alongside the
  dictionary. Worth remembering for any future code in this repo that
  builds a `[T]` from a `Dictionary`'s keys/values and expects order
  stability.

Verification (clean rebuild, both green):
```
cd BurlyKit && rm -rf .build && swift test
# Test run with 418 tests in 43 suites passed

BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
# Test run with 2 tests in 1 suite passed
```

Spec ambiguities interpreted (flagging for m7-03 / later M7 tasks):
- Real Hevy date format (`d MMM yyyy, HH:mm`) differs from
  `BurlyFixtures.HevyCSVGenerator`'s assumed `yyyy-MM-dd HH:mm:ss`.
  `HevyTimestamp.parse` tries both; if Dan's real export uses a third
  shape, every row will cleanly report as malformed (never silently
  misparsed) until m7-03 adds it.
- `weight_lbs`/`distance_miles` imperial column variants (seen in some
  public Hevy docs) are NOT supported — only the metric columns spec §8
  names. If Dan's export is imperial, the importer will abort with
  `unrecognizedHeader(missingColumns: ["weight_kg"])` (safe failure, not
  silent misinterpretation) rather than partially working.
- `set_index` is treated as informational only; set order comes from row
  order in the file. Real Hevy's numbering convention (global vs.
  per-exercise) couldn't be confirmed from the one public sample checked.
- `description` (session-level) maps to `SessionData.notes` — not in
  spec §8's explicit column list, but the domain field exists and
  dropping free text a user wrote seemed wrong. `exercise_notes`
  (per-set/per-exercise) has no domain home, so it's dropped-and-counted
  (`exerciseNotesDropped`) rather than silently discarded.
- Non-"normal"/"warmup" `set_type` values (not just Hevy's known
  "failure"/"dropset", but anything unrecognized) are flattened to a
  normal set and counted in `nonStandardSetTypeMarkersFlattened` — chose
  this over rejecting the row, since weight/reps are still good data.
- Repeated-exercise grouping is contiguous-run based (same exercise
  logged in two separate, non-adjacent blocks → two `SessionItemData`s).
  A cardio row that happens to sit between two blocks of the same
  strength exercise gets dropped before grouping, so the two blocks
  become contiguous (one item) once cardio noise is filtered out — this
  is deliberate but worth knowing if m7-03 finds a real export where
  that reads as unexpected merging.

Next: m7-03 (verify against Dan's real Hevy export — column names,
timestamp format, weight units, `set_index` semantics; correct the
"Pullover (Cable)" alias if wrong) and the later M7 persistence-wiring
task that consumes `HevyImportResult` (`sessions`, `newExercises`) via
`BurlyPersistence`.

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m7-01/BurlyKit
swift test        # 418 tests, 43 suites
BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
Branch `task/burly-m7-01` is clean and ready for review/PR; nothing
outside `BurlyKit/` was touched, `.github/workflows` untouched, no new
third-party dependencies (CryptoKit is a system framework).

## 2026-08-02 — Round-1 adversarial review (NOT-SAFE, 4 blockers + 13 majors) fixed

Done: all 4 blockers + 13 majors + 2 minors from
`.scratch/m7-01-review-1.md` fixed, one discriminating test each (34 new
tests, 445 total). Key changes: `CSVTokenizer` now emits a `Row` enum
(`.fields`/`.blank`/`.unterminatedQuote`/`.strayQuote`/`.oversizedRecord`)
instead of raw `[[String]]`; `HevyCSVImporter.parse` gained a
`timeZone:` param (default UTC) and strict→lossy UTF-8 decode;
`CatalogSeed.normalizedMatchKey` (trim+NFC+case-fold) is now the one
shared normalization rule for aliases, catalog names, and custom-exercise
identity hashing; `RowMetadataDrops` makes per-category accounting
fate-independent (counted for malformed/cardio/imported rows alike).
Verified 3 subtle fixes (2.1 occurrence keying, 1.1 lossy-decode, 7.1 NFC
hashing) by reverting each and confirming its test fails on old behavior.
Both verification commands green (445 tests / 2 spike tests). Nothing
disagreed with — all findings accepted and fixed as described.

Next: awaiting dispatcher re-review of round 2.

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m7-01/BurlyKit
swift test        # 445 tests, 43 suites
BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
Branch `task/burly-m7-01` clean, one commit ahead of db54ab7, not pushed.
