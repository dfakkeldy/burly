// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyRowDecoding
//
// Per-row validation and the transient grouping structures
// `HevyCSVImporter` builds sessions from. Everything here is internal: the
// module's public surface is `HevyCSVImporter.parse` and the result types
// in HevyImportTypes.swift.
import BurlyCore
import Foundation

/// One data row, fully validated and typed, before grouping into sessions.
struct DecodedRow {
    let title: String
    let startTimeRaw: String
    let startDate: Date
    let endDate: Date
    let exerciseTitle: String
    let weight: Weight
    let reps: Int
    let isWarmup: Bool
    /// `set_type` was present but was neither "normal" nor "warmup"
    /// (Hevy's "failure"/"dropset", or anything else) — flattened to a
    /// normal set, counted by the caller.
    let nonStandardSetType: Bool
    let hasSupersetID: Bool
    let hasRPE: Bool
    let hasExerciseNotes: Bool
    let description: String?
}

enum RowDecodeOutcome {
    case row(DecodedRow)
    /// Distance/duration-only row (spec §8) — dropped in full, never
    /// reaches set-level validation, so an empty weight/reps on a cardio
    /// row is never mistaken for a malformed strength row.
    case cardio
    case malformed(MalformedRow)
}

/// Decodes one data row. Never throws: every failure mode becomes a typed
/// `MalformedRowReason` instead, per the task's hostile-input requirement
/// that bad rows are dropped-and-accounted, not crash the import.
func decodeRow(
    fields: [String],
    header: HevyCSVHeader,
    expectedColumnCount: Int,
    rowNumber: Int
) -> RowDecodeOutcome {
    guard fields.count == expectedColumnCount else {
        return .malformed(MalformedRow(
            rowNumber: rowNumber,
            rawFields: fields,
            reason: .wrongColumnCount(expected: expectedColumnCount, actual: fields.count)
        ))
    }

    guard let title = header.value("title", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("title")))
    }
    guard let startTimeRaw = header.value("start_time", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("start_time")))
    }
    guard let endTimeRaw = header.value("end_time", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("end_time")))
    }
    guard let exerciseTitle = header.value("exercise_title", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("exercise_title")))
    }

    // Cardio detection happens before weight/reps validation: a cardio
    // row's weight/reps are legitimately empty, which must not be
    // reported as a malformed strength row.
    let distanceKm = header.value("distance_km", in: fields).flatMap(Double.init) ?? 0
    let durationSeconds = header.value("duration_seconds", in: fields).flatMap(Double.init) ?? 0
    if distanceKm > 0 || durationSeconds > 0 {
        return .cardio
    }

    let weightText = header.value("weight_kg", in: fields)
    let rawWeightKg: Double
    if let weightText {
        guard let parsed = Double(weightText) else {
            return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidWeight(weightText)))
        }
        rawWeightKg = parsed
    } else {
        rawWeightKg = 0 // empty column = bodyweight convention (spec §8)
    }
    guard let weight = try? Weight(validatingKg: rawWeightKg) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidWeight(weightText ?? "0")))
    }

    guard let repsText = header.value("reps", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("reps")))
    }
    guard let reps = Int(repsText), reps >= 0 else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidReps(repsText)))
    }

    guard let startDate = HevyTimestamp.parse(startTimeRaw) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidTimestamp(field: "start_time", value: startTimeRaw)))
    }
    guard let endDate = HevyTimestamp.parse(endTimeRaw) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidTimestamp(field: "end_time", value: endTimeRaw)))
    }

    // Blank set_type defaults to "normal" without any accounting — absent
    // is not "non-standard," it's just missing metadata for a column
    // Burly treats as informational anyway.
    let setTypeRaw = (header.value("set_type", in: fields) ?? "normal").lowercased()
    let isWarmup = setTypeRaw == "warmup"
    let isStandardSetType = setTypeRaw == "normal" || setTypeRaw == "warmup"

    return .row(DecodedRow(
        title: title,
        startTimeRaw: startTimeRaw,
        startDate: startDate,
        endDate: endDate,
        exerciseTitle: exerciseTitle,
        weight: weight,
        reps: reps,
        isWarmup: isWarmup,
        nonStandardSetType: !isStandardSetType,
        hasSupersetID: header.value("superset_id", in: fields) != nil,
        hasRPE: header.value("rpe", in: fields) != nil,
        hasExerciseNotes: header.value("exercise_notes", in: fields) != nil,
        description: header.value("description", in: fields)
    ))
}

/// One contiguous run of rows sharing the same (case-insensitive) exercise
/// title within a session — becomes one `SessionItemData`. A reference
/// type purely so `SessionAccumulator.append` can mutate the in-progress
/// run in place; neither type escapes `HevyCSVImporter.parse`.
final class ItemRun {
    let normalizedTitle: String
    /// The first-seen original casing/spacing, used as the display name if
    /// this run turns out to need a new custom exercise.
    let displayName: String
    private(set) var rows: [DecodedRow]

    init(firstRow: DecodedRow) {
        normalizedTitle = firstRow.exerciseTitle.lowercased()
        displayName = firstRow.exerciseTitle
        rows = [firstRow]
    }

    func append(_ row: DecodedRow) {
        rows.append(row)
    }
}

/// Accumulates every row belonging to one session (grouped by title +
/// start_time, spec §8) as it's encountered, preserving file order.
final class SessionAccumulator {
    let title: String
    let startTimeRaw: String
    let startDate: Date
    let endDate: Date
    /// First non-empty `description` seen for this session; Hevy repeats
    /// the same value on every row of a session, so "first wins" is
    /// equivalent to "the value" in practice.
    private(set) var description: String?
    private(set) var itemRuns: [ItemRun] = []

    init(title: String, startTimeRaw: String, startDate: Date, endDate: Date, description: String?) {
        self.title = title
        self.startTimeRaw = startTimeRaw
        self.startDate = startDate
        self.endDate = endDate
        self.description = description
    }

    func append(_ row: DecodedRow) {
        if description == nil { description = row.description }
        let normalized = row.exerciseTitle.lowercased()
        if let last = itemRuns.last, last.normalizedTitle == normalized {
            last.append(row)
        } else {
            itemRuns.append(ItemRun(firstRow: row))
        }
    }
}
