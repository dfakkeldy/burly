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
public enum HevyImportError: Error, Sendable, Equatable {
    /// The file's bytes were not valid UTF-8 text.
    case invalidEncoding
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
    /// shape (see `HevyTimestamp`).
    case invalidTimestamp(field: String, value: String)
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
    /// Rows whose `rpe` column had a value; the set was still imported,
    /// only the RPE number itself was discarded (Burly's schema has no RPE
    /// field).
    public let rpeValuesDropped: Int
    /// Rows whose `superset_id` column had a value; the set was still
    /// imported as an independent set, only the grouping was discarded
    /// (Burly's schema has no superset concept).
    public let supersetRowsDropped: Int
    /// Rows whose `set_type` was neither "normal" nor "warmup" (Hevy's
    /// "failure"/"dropset" markers, or anything else non-standard) —
    /// imported as a normal set per spec §8, counted here rather than
    /// silently coerced.
    public let nonStandardSetTypeMarkersFlattened: Int
    /// Rows whose `exercise_notes` column had a value; discarded (Burly's
    /// schema has no per-set/per-exercise-item note field).
    public let exerciseNotesDropped: Int
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
