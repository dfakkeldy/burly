// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyImportTypes
//
// Public surface for `HevyCSVImporter`'s result: the domain values it
// mapped, plus a dropped-data accounting (spec §8: "The import summary
// reports every dropped count") detailed enough that nothing the CSV
// contained but Burly's schema can't represent disappears unaccounted.
import BurlyCore
import Foundation

/// Whole-file failures. Anything short of these is handled per-row (see
/// `MalformedRow`) — spec §8: "only an unrecognizable header aborts."
///
/// There used to be a second case here, `.invalidEncoding`, thrown when
/// `parse(csvData:)`'s whole-file UTF-8 decode failed. Finding 1.1: a
/// single invalid byte anywhere in the file — even in one otherwise
/// unrelated row — made that whole-file decode return `nil` and abort
/// *every* row, violating "only an unrecognizable header aborts."
/// `parse(csvData:)` now falls back to a lossy decode (invalid byte
/// sequences become U+FFFD) when the strict decode fails, so decoding
/// itself can no longer fail; whichever row still carries a replacement
/// character is instead reported per-row via `MalformedRowReason
/// .invalidUTF8`, and a header that's corrupted enough to be
/// unrecognizable still aborts via `.unrecognizedHeader` below (a
/// replacement character breaks its exact column-name match).
public enum HevyImportError: Error, Sendable, Equatable {
    /// The header row (or its absence) is missing one or more columns
    /// BurlyImport needs to build anything at all. Lists the missing
    /// column names so a caller can show a specific message rather than a
    /// generic "couldn't read this file."
    case unrecognizedHeader(missingColumns: [String])
}

/// Why one data row couldn't be turned into a set. Carried alongside the
/// row's raw fields and its 1-based position in the file (header is row 1)
/// so a caller can show the user exactly what was skipped and why.
public enum MalformedRowReason: Sendable, Equatable {
    /// The row's field count didn't match the header's.
    case wrongColumnCount(expected: Int, actual: Int)
    /// A required column's value was blank where blank isn't a valid
    /// default for that field (unlike `weight_kg`, where blank means
    /// bodyweight).
    case missingRequiredField(String)
    /// `weight_kg` didn't parse as a number, or parsed to something
    /// `Weight` itself rejects (negative, NaN, infinite).
    case invalidWeight(String)
    /// `reps` didn't parse as a non-negative integer.
    case invalidReps(String)
    /// `start_time` or `end_time` didn't match either known Hevy timestamp
    /// shape (see `HevyTimestamp`), including a shape that doesn't follow
    /// the exact supported grammar (finding 6.3).
    case invalidTimestamp(field: String, value: String)
    /// `end_time` parsed to an instant before `start_time` (finding 6.2).
    case endBeforeStart
    /// A nonempty `distance_km` or `duration_seconds` value didn't parse
    /// as a finite, non-negative number (finding 5.1) — garbage text,
    /// `NaN`, a negative value, or positive infinity.
    case invalidDistance(String)
    case invalidDuration(String)
    /// The row's bytes could not be decoded as UTF-8 even under a lossy
    /// fallback decode of the whole file — this row still carries a
    /// Unicode replacement character (finding 1.1).
    case invalidUTF8
    /// A genuinely blank physical record between two data rows (finding
    /// 1.7) — visibly counted rather than silently vanishing and shifting
    /// subsequent row numbers.
    case blankRow
    /// A quote was still open when a failure was discovered — either the
    /// file ended with it never closed (finding 1.3), or a field/record
    /// size bound tripped on content inside it. m7-01 round 3: resyncing
    /// after a quoted-context failure is NOT safe (a bounded "how many
    /// embedded terminators" guard was proven to let a legitimate
    /// multi-line note get resynced mid-content and misread as a
    /// fabricated row) — so everything from the point of failure to the
    /// true end of the file is discarded as ONE record, never
    /// reinterpreted as CSV structure again. `approxRowsLost` is an
    /// honest, approximate count of physical rows skipped that way (0 when
    /// the failure was discovered exactly at EOF, with nothing left to
    /// skip). See `HevyImportSummary.rowsLostToUnterminatedQuote` for the
    /// whole-file total surfaced to callers.
    case unterminatedQuoteConsumedRemainder(approxRowsLost: Int)
    /// A `"` appeared somewhere other than the true start of a field
    /// (finding 1.4) — e.g. an unquoted `1"2"` value.
    case strayQuoteInField
    /// A closing quote was immediately followed by something other than a
    /// separator/CR/LF/CRLF/EOF (m7-01 review round 2, new defect #1) —
    /// e.g. `"Bench Press (Barbell)"junk`. The value up to the closing
    /// quote is well-formed; the trailing content glued onto it is not.
    case contentAfterClosingQuote
    /// One of `CSVTokenizer`'s bounds (field size, total record size, or
    /// field count) was exceeded before the record ended (finding 1.5,
    /// plus the round-2 record-size/field-count gaps).
    case oversizedRecord(OversizedRecordLimit)
}

/// Which of `CSVTokenizer`'s bounds was exceeded to produce
/// `.oversizedRecord` above — every bound reports through that one case,
/// but callers can still tell which limit was hit and what its value was.
public enum OversizedRecordLimit: Sendable, Equatable {
    /// A single field grew past `CSVTokenizer.maxFieldLength` scalars.
    case fieldLength(Int)
    /// The record's total content (summed across every field) grew past
    /// `CSVTokenizer.maxRecordLength` scalars.
    case recordLength(Int)
    /// The record accumulated more fields (commas) than
    /// `CSVTokenizer.maxFieldsPerRecord` allows.
    case fieldCount(Int)
}

public struct MalformedRow: Sendable, Equatable {
    /// 1-based position in the file; the header row is row 1, so the first
    /// data row is row 2.
    public let rowNumber: Int
    public let rawFields: [String]
    public let reason: MalformedRowReason
}

/// Every dropped-or-altered count spec §8 calls out, plus the counts
/// needed to describe what *did* make it in. `sessionsImported`/
/// `setsImported`/exercise counts mirror exactly what's in the sibling
/// `HevyImportResult.sessions`/`newExercises` — computed once, during the
/// same pass that builds them, so a preview built from this summary can
/// never drift from the values the same parse actually produced (spec §8
/// acceptance #4's concern, for whichever later task wires up the preview
/// screen).
///
/// CONTRACT (m7-01 round 3 finding 3.1): the per-category dropped-value
/// counts below (`rpeValuesDropped`, `supersetRowsDropped`,
/// `exerciseNotesDropped`, `setIndexValuesDropped`,
/// `unknownColumnValuesDropped`, `nonStandardSetTypeMarkersFlattened`)
/// cover ONLY rows that reached field-level decoding — i.e. rows the
/// tokenizer successfully split into named fields (`CSVTokenizer.Row
/// .fields`), whatever `decodeRow` then did with them (imported, cardio,
/// or malformed for some other reason). A row the TOKENIZER itself
/// couldn't safely turn into fields at all — blank, an unterminated quote,
/// a stray quote, content glued onto a closing quote, or an oversized
/// record — never reaches field decoding, so it is NEVER reflected in
/// these counters; there is no safe way to scan for an `rpe`/`superset_id`
/// value inside data that was never reliably tokenized; inventing a count
/// from unparseable bytes would be worse than reporting none. Every such
/// row is instead fully accounted for in `malformedRows`, with a
/// `MalformedRowReason` naming exactly why it couldn't be tokenized.
public struct HevyImportSummary: Sendable, Equatable {
    public let sessionsImported: Int
    public let setsImported: Int
    /// Count of distinct catalog exercises (curated or alias-resolved)
    /// referenced by at least one imported set.
    public let exercisesMatched: Int
    /// Count of distinct new `origin: .hevyImport` exercises created for
    /// names that matched neither the alias table nor a catalog name.
    public let exercisesCreatedAsCustom: Int
    /// Rows skipped in full because they were cardio (distance/duration
    /// only) — out of scope per spec §8, Apple Workout owns cardio.
    public let cardioRowsSkipped: Int
    /// Every row whose `rpe` column had a value, regardless of whether the
    /// row went on to become an imported set, a skipped cardio row, or a
    /// malformed row for an unrelated reason (m7-01 review findings
    /// 4.1/4.2: a value present in the file is counted as dropped the
    /// moment Burly's schema can't carry it, independent of that row's
    /// other fate) — see the struct's CONTRACT doc for the scope this
    /// "regardless of fate" promise does NOT extend to (tokenizer-level
    /// failures). Burly's schema has no RPE field.
    public let rpeValuesDropped: Int
    /// Every row whose `superset_id` column had a value (same
    /// fate-independent counting, and the same tokenizer-level-failure
    /// exclusion, as `rpeValuesDropped` above). Burly's schema has no
    /// superset concept.
    public let supersetRowsDropped: Int
    /// Every row whose `set_type` was present and neither "normal" nor
    /// "warmup" (Hevy's "failure"/"dropset" markers, or anything else
    /// non-standard) — same fate-independent counting, and the same
    /// tokenizer-level-failure exclusion, as `rpeValuesDropped` above. An
    /// imported row with a non-standard `set_type` still becomes a normal
    /// set per spec §8; this counts the marker's presence in the file
    /// either way, not just the imported case.
    public let nonStandardSetTypeMarkersFlattened: Int
    /// Every row whose `exercise_notes` column had a value (same
    /// fate-independent counting, and the same tokenizer-level-failure
    /// exclusion, as `rpeValuesDropped` above). Burly's schema has no
    /// per-set/per-exercise-item note field.
    public let exerciseNotesDropped: Int
    /// Every row whose `set_index` column had a value (finding 4.4; same
    /// fate-independent counting, and the same tokenizer-level-failure
    /// exclusion, as `rpeValuesDropped` above). Read only to report that it
    /// was discarded — see `HevyCSVImporter`'s doc comment on why set order
    /// is taken from row order instead.
    public let setIndexValuesDropped: Int
    /// Total count of nonempty values found in header columns this
    /// importer doesn't recognize at all (finding 4.3) — e.g. a `tempo` or
    /// `failure_reason` column Hevy might add later. The header itself is
    /// still accepted; only the unrecognized columns' values are dropped.
    public let unknownColumnValuesDropped: Int
    /// Count of individual `end_time`/description values dropped because
    /// they disagreed with the value an earlier row in the same session
    /// already established (finding 4.5) — the disagreeing row's *set* is
    /// still imported; only the conflicting session-level value is
    /// discarded, since Hevy's convention is that every row of a session
    /// repeats the same session-level values.
    public let conflictingSessionMetadataDropped: Int
    /// Sum of `approxRowsLost` across every
    /// `.unterminatedQuoteConsumedRemainder` malformed row (m7-01 round 3
    /// finding: this must be surfaced honestly, not buried only inside
    /// `malformedRows`' reasons). An open quote whose failure is discovered
    /// mid-file consumes the rest of the file as one malformed record
    /// rather than risk an unsafe resynchronization (see
    /// `CSVTokenizer`'s FAILURE-MODE TABLE) — this is the whole-file total
    /// of physical rows that cost, approximated by counting terminators
    /// skipped while doing so. Zero on a file with no such failure.
    public let rowsLostToUnterminatedQuote: Int
    /// `true` when this file's bytes required the lossy UTF-8 fallback
    /// decode (m7-01 round 3 finding 4.1) — i.e. at least one byte
    /// anywhere in the file was not valid UTF-8. When this is `true`,
    /// EVERY row containing a U+FFFD scalar is conservatively quarantined
    /// as `.invalidUTF8`, including a row whose U+FFFD was always genuine
    /// content rather than decode corruption: this module cannot yet tell
    /// the two apart without byte-range-precise tracking through the
    /// decode step, and quarantining a few clean rows is preferred over
    /// ever risking importing corrupted bytes as real data. Byte-range
    /// precision (only flagging the specific row whose bytes actually
    /// failed to decode) is deferred to m7-03, once a real Hevy export is
    /// in hand to validate the approach against. `false` means the whole
    /// file decoded as strict UTF-8, so any U+FFFD present is unconditionally
    /// legitimate content and never quarantined for encoding reasons.
    public let encodingDamageDetected: Bool
    /// Every row that couldn't be turned into a set at all, with why.
    public let malformedRows: [MalformedRow]

    public var malformedRowCount: Int { malformedRows.count }

    public init(
        sessionsImported: Int,
        setsImported: Int,
        exercisesMatched: Int,
        exercisesCreatedAsCustom: Int,
        cardioRowsSkipped: Int,
        rpeValuesDropped: Int,
        supersetRowsDropped: Int,
        nonStandardSetTypeMarkersFlattened: Int,
        exerciseNotesDropped: Int,
        setIndexValuesDropped: Int,
        unknownColumnValuesDropped: Int,
        conflictingSessionMetadataDropped: Int,
        rowsLostToUnterminatedQuote: Int,
        encodingDamageDetected: Bool,
        malformedRows: [MalformedRow]
    ) {
        self.sessionsImported = sessionsImported
        self.setsImported = setsImported
        self.exercisesMatched = exercisesMatched
        self.exercisesCreatedAsCustom = exercisesCreatedAsCustom
        self.cardioRowsSkipped = cardioRowsSkipped
        self.rpeValuesDropped = rpeValuesDropped
        self.supersetRowsDropped = supersetRowsDropped
        self.nonStandardSetTypeMarkersFlattened = nonStandardSetTypeMarkersFlattened
        self.exerciseNotesDropped = exerciseNotesDropped
        self.setIndexValuesDropped = setIndexValuesDropped
        self.unknownColumnValuesDropped = unknownColumnValuesDropped
        self.conflictingSessionMetadataDropped = conflictingSessionMetadataDropped
        self.rowsLostToUnterminatedQuote = rowsLostToUnterminatedQuote
        self.encodingDamageDetected = encodingDamageDetected
        self.malformedRows = malformedRows
    }
}

/// The full result of parsing and mapping one Hevy export. `sessions` and
/// `newExercises` are ready to hand to BurlyPersistence once a later M7
/// task wires up that seam; this module does no persistence of its own.
public struct HevyImportResult: Sendable, Equatable {
    /// In file order (by first-appearing row of each session), not sorted
    /// by date — callers that want chronological order sort this
    /// themselves.
    public let sessions: [SessionData]
    /// New `origin: .hevyImport` exercises this import needs created
    /// before `sessions` can be persisted (their `exerciseID`s reference
    /// these). Deduplicated by normalized name across the whole file.
    public let newExercises: [ExerciseData]
    public let summary: HevyImportSummary

    public init(sessions: [SessionData], newExercises: [ExerciseData], summary: HevyImportSummary) {
        self.sessions = sessions
        self.newExercises = newExercises
        self.summary = summary
    }
}
