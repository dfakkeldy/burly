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
    /// The record's last field was still inside an open quote when
    /// scanning it ended (finding 1.3) — the record is discarded rather
    /// than importing whatever partial value it absorbed.
    case unterminatedQuote
    /// A `"` appeared somewhere other than the true start of a field
    /// (finding 1.4) — e.g. an unquoted `1"2"` value.
    case strayQuoteInField
    /// A field grew past `CSVTokenizer.maxFieldLength` scalars before its
    /// record ended (finding 1.5).
    case oversizedRecord(limitScalars: Int)
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
    /// other fate). Burly's schema has no RPE field.
    public let rpeValuesDropped: Int
    /// Every row whose `superset_id` column had a value (same
    /// fate-independent counting as `rpeValuesDropped` above). Burly's
    /// schema has no superset concept.
    public let supersetRowsDropped: Int
    /// Every row whose `set_type` was present and neither "normal" nor
    /// "warmup" (Hevy's "failure"/"dropset" markers, or anything else
    /// non-standard) — same fate-independent counting as
    /// `rpeValuesDropped` above. An imported row with a non-standard
    /// `set_type` still becomes a normal set per spec §8; this counts the
    /// marker's presence in the file either way, not just the imported
    /// case.
    public let nonStandardSetTypeMarkersFlattened: Int
    /// Every row whose `exercise_notes` column had a value (same
    /// fate-independent counting as `rpeValuesDropped` above). Burly's
    /// schema has no per-set/per-exercise-item note field.
    public let exerciseNotesDropped: Int
    /// Every row whose `set_index` column had a value (finding 4.4; same
    /// fate-independent counting as `rpeValuesDropped` above). Read only
    /// to report that it was discarded — see `HevyCSVImporter`'s doc
    /// comment on why set order is taken from row order instead.
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
