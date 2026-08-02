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

## 2026-08-02 — Round-2 review (NOT-SAFE): CSVTokenizer redesigned as an explicit state machine, remaining findings fixed

Done: dispatcher's diagnosis was "the hand-rolled tokenizer state machine
has accreted patches — redesign it cleanly." `CSVTokenizer.swift` rewritten
from scratch as an explicit state machine (`fieldStart` / `unquotedField` /
`quotedField` / `quoteSeen` / `recordError`, each documented in the file's
header comment) instead of the old single `inQuotes` boolean plus ad-hoc
flags. Every malformed condition now funnels through one `enterRecordError`
transition, so "resynchronize at the next record terminator" is one
mechanism, not N patches:
- Property 1 (record-local recovery): a still-open quoted field can no
  longer swallow arbitrarily many subsequent physical rows or let a LATER
  row's quote falsely close it and merge rows — bounded by a new
  `maxEmbeddedTerminatorsPerRecord` (32) "runaway-quote guard": once a
  quote absorbs more embedded line breaks than that, the tokenizer gives up
  waiting for it to close and resynchronizes. Verified against the actual
  old tokenizer (stashed, ran a throwaway diagnostic) that it swallows all
  50 subsequent rows into one `.unterminatedQuote` for this exact scenario.
- Property 2 (strict post-quote transitions): new `quoteSeen` state — only
  `,`/CR/LF/CRLF/EOF are legal right after a closing quote; anything else
  (e.g. `"a"junk`) is `.contentAfterClosingQuote`, a new `Row`/
  `MalformedRowReason` case, instead of being silently glued onto the value.
- Property 3 (bounded everything): added `maxRecordLength` (4× the
  pre-existing `maxFieldLength`, total content across one record) and
  `maxFieldsPerRecord` (4096) alongside the existing per-field bound; all
  three report `.oversizedRecord(OversizedRecordLimit)` (new associated
  enum: `.fieldLength`/`.recordLength`/`.fieldCount` — was a bare case with
  a hardcoded `limitScalars` at the call site before).
- Property 4: every previously-pinned behavior (quoted commas/newlines/
  escaped quotes, CRLF/LF/bare-CR terminators, CR literal in quotes, blank
  rows, no-trailing-newline EOF) re-verified passing unchanged.
- Permanent adversarial fuzz test added (`adversarialFuzzNeverCrashesOrOverlaps`):
  fixed-seed deterministic PRNG (`SplitMix64`), 300 trials of up to 200
  hostile scalars from a small adversarial alphabet, asserts no crash/hang
  and no overlapping field content.

Secondary fixes (all review-2 remaining items):
- U+FFFD honesty: `HevyCSVImporter.parse` split into `parseImpl` with a
  `strictDecodeSucceeded` flag threaded from the `csvData:` overload (the
  `csv: String` overload always passes `true` — a `String` is by
  definition already validly decoded). A row's U+FFFD is only flagged
  `.invalidUTF8` when the WHOLE FILE needed the lossy fallback; the flag
  is checked inside `decodeRow` itself (after `drops` is computed), not as
  a pre-decode early return in the caller, so a flagged row still gets
  full metadata-drop accounting.
- `CatalogSeed.validate()`: added `ambiguousExerciseNameNormalization`
  (two exercise names collide once normalized) and
  `aliasCollidesWithExerciseName` (an alias collides with a DIFFERENT
  exercise's name) — closes review §2.3. Bundled seed still passes
  (pinned with a dedicated test).
- Drop accounting completeness: `decodeRow` now computes `RowMetadataDrops`
  before the wrong-column-count guard (was an unconditional
  `RowMetadataDrops()`); `HevyCSVHeader.unknownColumnIndices` tracks every
  unknown column's raw index instead of deduplicating by name, so
  `header,tempo,tempo` with two nonempty values now counts 2 dropped
  values, not 1.
- `HevyTimestamp`'s real-export-shape date-token split changed to
  `omittingEmptySubsequences: false`, rejecting an internal double space
  (`2  Jan 2025, 08:00`) that the documented single-space grammar
  disallows.

Verification: every new/changed test manually confirmed to fail against
the pre-fix behavior (reverted each fix in isolation — via `git stash` for
the tokenizer, via temporary inline reverts for the rest — reran the
specific new test, confirmed failure, restored). No disagreements with the
dispatcher's diagnosis or either review; all findings fixed as described.

```
cd BurlyKit && rm -rf .build && swift test
# Test run with 466 tests in 43 suites passed

BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
# Test run with 2 tests in 1 suite passed
```

Next: awaiting dispatcher re-review of round B (round 3).

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m7-01/BurlyKit
swift test        # 466 tests, 43 suites
BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
Branch `task/burly-m7-01`, commit e98f134 on top of 5693e85, not pushed.

## 2026-08-02 — Round-3 review (NOT-SAFE, narrow finding set): runaway-quote guard removed as an injection vector; state-clobber, off-by-one, and accounting-contract fixes (round C)

Done: dispatcher adjudications implemented exactly as directed.

**Adjudication 1 (the big one) — `maxEmbeddedTerminatorsPerRecord` REMOVED, not
retuned.** The reviewer proved round B's "runaway-quote guard" was an
injection vector: a legitimate free-form Hevy note could exceed any fixed
embedded-terminator bound, get resynced MID-CONTENT, and have one of its
own lines misread as a fabricated workout row — silent row-boundary
corruption, worse than the data loss the guard was meant to prevent. New
rule, implemented exactly as adjudicated: resynchronization is only
trustworthy in UNQUOTED context. `CSVTokenizer` gained a new terminal state,
`consumeToEOF`: any failure discovered while a quote is still open
(unterminated quote at true EOF, or a field/record bound tripping on
content inside an open quote) consumes every remaining scalar to the true
end of the file WITHOUT buffering (bounded memory — just skip), then emits
exactly ONE `.unterminatedQuoteConsumedRemainder(approxRowsLost:)` —
`approxRowsLost` counts terminators seen while skipping (0 when the
failure was discovered exactly at EOF, with nothing left to skip). Bounds
tripped OUTSIDE any open quote (stray quote, content-after-closing-quote,
oversized field/record/field-count in unquoted content) are unaffected —
they still resynchronize at the next terminator via `recordError`, since
that recovery was never the unsafe part. Renamed `MalformedRowReason
.unterminatedQuote` → `.unterminatedQuoteConsumedRemainder(approxRowsLost:)`
to match. Full failure-mode table (quoted vs. unquoted context) is
documented in `CSVTokenizer.swift`'s file header.

**FIX 2 (High, finding 1.1) — state clobber.** `quoteSeen`'s escaped-quote
branch called `appendToField` (which can trip a bound and enter an error
state) then unconditionally reassigned `state = .quotedField` right after,
silently undoing the error transition. Guarded the same way `handleComma`
already was (`if state != .recordError && state != .consumeToEOF`).
Verified the exact dangerous consequence by temporarily reintroducing the
clobber: with the bug present, the reviewer's scenario (four ~1 MiB
fields, then `"abcd"""` positioned so the escaped quote's append trips the
per-record bound, followed by `,lastfield` and a well-formed `good,row`)
produced `[.fields(["header"]), .oversizedRecord(.recordLength(_)),
.fields(["good", "row"])]` — the oversized record silently resynced and
`good,row` imported as if nothing were wrong. Fixed, it correctly produces
`[.fields(["header"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 2)]`.
Pinned in `CSVTokenizerTests.escapedQuoteAppendTrippingBoundIsNotClobbered`.

**FIX 3 (Medium, 3.1) — contract text + no faked counts.** `oversizedRecord`/
tokenizer-level malformed rows were never scanned for per-category drops
(correct — the row was never safely tokenized, and there is no safe way to
scan unparseable bytes for an `rpe`/`superset_id` value). This was already
true in the code; the gap was that `HevyImportSummary`'s doc didn't say so.
Added an explicit CONTRACT paragraph to the struct doc: per-category counts
cover only rows that reached field-level decoding; tokenizer-level failures
are covered by `malformedRows` + reasons instead. Pinned with
`tokenizerLevelFailuresNeverFakeDropCounts` (blank/stray-quote/
content-after-close rows all report zero across every per-category
counter).

**FIX 4 (Low, 3.2) — field-count off-by-one.** `startNewField`'s bound
check was `fieldCount <= maxFieldsPerRecord` evaluated AFTER incrementing
for the field just started, which actually permitted
`maxFieldsPerRecord + 1` fields before ever tripping. Changed to `fieldCount
< maxFieldsPerRecord`. Verified by temporarily reintroducing the `<=` form:
`oneMoreThanMaxFieldsPerRecordIsOversized` (4097 fields) failed as expected;
restored, both it and `exactlyMaxFieldsPerRecordIsLegal` (4096 fields) pass.

**FIX 5 (Medium, 4.1) — mixed invalid-byte + genuine-U+FFFD file.** Kept the
conservative quarantine (every U+FFFD-bearing row is flagged when the whole
file needed the lossy decode fallback, even a row whose U+FFFD was always
genuine content) but surfaced it: added `HevyImportSummary
.encodingDamageDetected: Bool`. Byte-range precision (flagging only the
row whose bytes actually failed) is deferred to m7-03 — noted in the
summary's doc and here. Pinned with
`coexistingInvalidByteAndLegitimateReplacementCharacterAreBothQuarantinedAndFlagged`
(both rows flagged, flag set) and `cleanFileReportsNoEncodingDamage` (flag
clear on a normal file).

**FIX 1's "surface honestly" + FIX 6 (Medium, 6.1) — fuzz test
strengthening.**
- Added `HevyImportSummary.rowsLostToUnterminatedQuote: Int` (sum of
  `approxRowsLost` across every `.unterminatedQuoteConsumedRemainder`
  malformed row) so the whole-file cost is visible directly on the
  summary. Pinned in `rowsLostToUnterminatedQuoteIsSurfacedOnSummary`.
- `CSVTokenizer` gained a test/diagnostic-only `rowsWithDiagnostics(in:
  iterationBudget:)` entry point (production `rows(in:)` is an unchanged
  thin wrapper — zero added cost) that exposes, per main-loop iteration,
  the exact scalar range consumed, plus an explicit iteration budget.
- Retitled and re-split the adversarial fuzz test into two, each claiming
  exactly what it proves (reviewer measured ZERO trials in the old version
  ever reaching a bound):
  - `adversarialFuzzShortHostileInputsFullCoverage`: 300 short
    (≤200-scalar) trials from a hostile alphabet, asserting (a) no crash,
    (b) termination via the explicit iteration budget (not the test
    timeout), (c) full/non-overlapping/single-pass scalar coverage
    mechanically reconstructed from the diagnostic step ranges.
  - `adversarialFuzzBoundTrippingAndQuotedHeavyShapes`: 15 trials
    deliberately building long quoted runs that straddle
    `maxFieldLength`, with embedded terminators and an escaped-quote pair
    placed right at the boundary (mirroring finding 1.1's shape) — asserts
    the same coverage/termination properties AND that at least one trial
    actually trips a bound or the consume-to-EOF path.
  - The coverage assertion loop scans plain Swift first and calls
    `#expect` a fixed handful of times per trial rather than once per
    step — a huge quoted field can produce millions of single-scalar
    steps, and one `#expect` per step was measured at ~14s; the
    scan-then-assert-once version runs in ~3s for the whole suite.

Verified no regression on every round-1/round-2 pin the round-3 review
confirmed closed (re-ran by name):
`twoAliasesOfSameExerciseInOneSessionGetDistinctIDs`,
`bothTimestampFormatsForSameInstantProduceSameSessionID`,
`bomIsStrippedBeforeHeaderResolution`, `bareCRInsideQuotesIsPreserved`,
`blankInteriorRecordIsReportedNotSilentlyDropped`,
`tokenizerLevelMalformedRecordsSurfaceAsMalformedRows`,
`contentAfterClosingQuoteIsMalformed`,
`contentAfterClosingQuoteNeverCreatesACorruptedExercise` — all green.

Every fix pinned by a test manually confirmed to fail against the pre-fix
behavior (temporary inline reverts, reran the specific test, confirmed
failure, restored — confirmed no `TEMP` markers or diff drift remained
afterward via `git diff --stat` before committing). No disagreements with
the dispatcher's adjudications; all fixed exactly as directed.

```
cd BurlyKit && rm -rf .build && swift test
# Test run with 474 tests in 43 suites passed

BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
# Test run with 2 tests in 1 suite passed
```

Spec/design note for whoever picks this up next: `CSVTokenizer`'s new
FAILURE-MODE TABLE (top of `CSVTokenizer.swift`) is now the canonical
reference for "what happens on failure X in context Y" — read it before
touching tokenizer error-recovery again; the round-2→round-3 history is a
cautionary tale about tuning a bound instead of asking whether
resynchronization is safe at all in that context.

Next: awaiting dispatcher re-review of round C.

Resume:
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m7-01/BurlyKit
swift test        # 474 tests, 43 suites
BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
Branch `task/burly-m7-01`, commit e70229e on top of e98f134, not pushed.

## 2026-08-02 — Round-4 review: containment CONFIRMED secure, two LOW findings fixed (round D, final round)

Round 4 confirmed containment secure — entry paths complete, no partial-row
leaks, tiling proven, all round-1/2/3 regressions pass — with exactly two
LOW findings. Both fixed in this round; **this closes the task** pending
final dispatcher sign-off (no more open findings expected).

**Finding 1 — `approxRowsLost` undercount.** The scalar that trips a
quoted-context bound was being advanced by `CSVTokenizer`'s `quotedField`
case's own `i += 1` BEFORE `consumeToEOF`'s skip loop ever got a chance to
count it, so a bound tripped BY a terminator silently omitted that
terminator from the count. Fixed by checking `terminatorLength(at: i)`
*before* calling `appendToField` in the `quotedField` case: if the append
trips the bound AND the scalar is (or begins) a line terminator, that
terminator is counted as the first lost row and its full width (1 for a
lone CR/LF, 2 for a CRLF pair) is skipped on entry to `consumeToEOF` —
"CRLF still once" falls out for free since `terminatorLength(at:)`
evaluated at the LF's own position already reports length 1 when only the
LF (not the CR) is what trips it. Pinned with both exact reviewer
triggers: `boundTrippedByLFStillCountsIt` (quote + `maxFieldLength` x's +
LF + EOF → 1, was 0) and `boundTrippedByLFHalfOfCRLFStillCountsItOnce`
(`maxFieldLength - 1` x's + CRLF → 1, was 0). Verified both fail against
the pre-fix code (reverted to the old unconditional `i += 1`, confirmed
both report `approxRowsLost: 0`, restored).

**Finding 2 — fuzz "bound tripped" helper over-broad.** The bound-trip
detector in `assertFullCoverageNoCrashNoHang` matched ANY
`.unterminatedQuoteConsumedRemainder`, but that case's `approxRowsLost: 0`
variant is ALSO exactly what an ordinary "ran out of input while quoted,
no bound ever tripped" outcome reports — so a short unterminated trailing
quote (which the short-hostile-input corpus produces easily) could satisfy
the "bounds actually trip" guarantee in `adversarialFuzzBoundTrippingAndQuotedHeavyShapes`
without any bound ever having tripped. Fixed the detector to require
`.oversizedRecord` OR `.unterminatedQuoteConsumedRemainder` with
`approxRowsLost > 0` (that counter is airtight — it only ever increments
inside `consumeToEOF`, entered only via a genuine bound trip). Also
tightened the corpus generator itself per the adjudication's "adjust the
seed corpus if needed so the guarantee is real": trial 0's oversized field
is no longer left to the probabilistic branch (whose range could, for
some RNG draws, land just under `maxFieldLength` and trip nothing) — it's
now deterministically forced to `maxFieldLength + 100`, guaranteeing a
genuine trip regardless of RNG behavior. Verified empirically (a
standalone script running the OLD detector's exact switch statement
against `.unterminatedQuoteConsumedRemainder(approxRowsLost: 0)`) that the
prior detector does report `true` for a natural, bound-free case — proving
the fix's distinction is real, not cosmetic.

```
cd BurlyKit && rm -rf .build && swift test
# Test run with 476 tests in 43 suites passed

BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
# Test run with 2 tests in 1 suite passed
```

Resume (if anything further comes back):
```
cd /Users/dfakkeldy/Developer/worktrees/burly-m7-01/BurlyKit
swift test        # 476 tests, 43 suites
BURLY_RUN_MIGRATION_SPIKE=1 swift test --filter MigrationSpikeTests
```
Branch `task/burly-m7-01`, commit pending on top of e70229e, not pushed.
Task closes after this round pending final dispatcher confirmation.
