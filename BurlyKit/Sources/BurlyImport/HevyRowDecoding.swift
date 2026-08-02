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
    let startDate: Date
    let endDate: Date
    let exerciseTitle: String
    let weight: Weight
    let reps: Int
    let isWarmup: Bool
    let description: String?
}

/// Per-row dropped/altered metadata counts (m7-01 review findings
/// 4.1/4.2/4.3/4.4): computed once from a row's raw field values,
/// independent of whether that same row goes on to become an imported set,
/// a skipped cardio row, or a malformed row for an unrelated reason. A
/// value present in the file is "dropped" the moment Burly's schema can't
/// carry it forward, regardless of what else is (or isn't) wrong with that
/// row — so every `RowDecodeOutcome` case below carries one of these,
/// including `.malformed`.
struct RowMetadataDrops: Equatable {
    var hasRPE = false
    var hasSupersetID = false
    var hasExerciseNotes = false
    var hasSetIndexValue = false
    var nonStandardSetType = false
    var unknownColumnValueCount = 0
}

enum RowDecodeOutcome {
    case row(DecodedRow, RowMetadataDrops)
    /// Distance/duration-only row (spec §8) — dropped in full, never
    /// reaches set-level validation, so an empty weight/reps on a cardio
    /// row is never mistaken for a malformed strength row.
    case cardio(RowMetadataDrops)
    case malformed(MalformedRow, RowMetadataDrops)
}

/// Decodes one data row. Never throws: every failure mode becomes a typed
/// `MalformedRowReason` instead, per the task's hostile-input requirement
/// that bad rows are dropped-and-accounted, not crash the import.
func decodeRow(
    fields: [String],
    header: HevyCSVHeader,
    expectedColumnCount: Int,
    rowNumber: Int,
    timeZone: TimeZone = HevyTimestamp.defaultTimeZone
) -> RowDecodeOutcome {
    // A wrong column count means `fields` can't be reliably mapped to the
    // header's named positions at all (a shifted/ragged row) — attempting
    // per-category metadata counting from misaligned data would itself be
    // unreliable, so this is the one failure that reports zero drops
    // rather than a best-effort (and potentially wrong) count.
    guard fields.count == expectedColumnCount else {
        return .malformed(
            MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .wrongColumnCount(expected: expectedColumnCount, actual: fields.count)),
            RowMetadataDrops()
        )
    }

    // Findings 4.1/4.2/4.3/4.4: every dropped-metadata count is computed
    // up front, before any validation that could return early, so it's
    // never possible for a row's fate (malformed / cardio / imported) to
    // determine whether its rpe/superset/notes/set_index/unknown-column
    // values get counted.
    let setTypeRaw = (header.value("set_type", in: fields) ?? "normal").lowercased()
    let isStandardSetType = setTypeRaw == "normal" || setTypeRaw == "warmup"
    let drops = RowMetadataDrops(
        hasRPE: header.value("rpe", in: fields) != nil,
        hasSupersetID: header.value("superset_id", in: fields) != nil,
        hasExerciseNotes: header.value("exercise_notes", in: fields) != nil,
        hasSetIndexValue: header.value("set_index", in: fields) != nil,
        nonStandardSetType: !isStandardSetType,
        unknownColumnValueCount: header.unknownColumnNames.reduce(into: 0) { count, column in
            if header.value(column, in: fields) != nil { count += 1 }
        }
    )

    guard let title = header.value("title", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("title")), drops)
    }
    guard let startTimeRaw = header.value("start_time", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("start_time")), drops)
    }
    guard let endTimeRaw = header.value("end_time", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("end_time")), drops)
    }
    guard let exerciseTitle = header.value("exercise_title", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("exercise_title")), drops)
    }

    // Cardio detection happens before weight/reps validation: a cardio
    // row's weight/reps are legitimately empty, which must not be
    // reported as a malformed strength row. Finding 5.1: a *nonempty*
    // distance/duration value must parse as a finite, non-negative number
    // or the row is malformed outright — garbage text, "NaN", a negative
    // value, or positive infinity must never silently fall through to "0
    // => not cardio" or "any positive value => an ordinary cardio row".
    let distanceText = header.value("distance_km", in: fields)
    let durationText = header.value("duration_seconds", in: fields)
    if let distanceText {
        guard let value = Double(distanceText), value.isFinite, value >= 0 else {
            return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidDistance(distanceText)), drops)
        }
    }
    if let durationText {
        guard let value = Double(durationText), value.isFinite, value >= 0 else {
            return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidDuration(durationText)), drops)
        }
    }
    let distanceKm = distanceText.flatMap(Double.init) ?? 0
    let durationSeconds = durationText.flatMap(Double.init) ?? 0
    if distanceKm > 0 || durationSeconds > 0 {
        return .cardio(drops)
    }

    let weightText = header.value("weight_kg", in: fields)
    let rawWeightKg: Double
    if let weightText {
        guard let parsed = Double(weightText) else {
            return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidWeight(weightText)), drops)
        }
        rawWeightKg = parsed
    } else {
        rawWeightKg = 0 // empty column = bodyweight convention (spec §8)
    }
    guard let weight = try? Weight(validatingKg: rawWeightKg) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidWeight(weightText ?? "0")), drops)
    }

    guard let repsText = header.value("reps", in: fields) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .missingRequiredField("reps")), drops)
    }
    guard let reps = Int(repsText), reps >= 0 else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidReps(repsText)), drops)
    }

    guard let startDate = HevyTimestamp.parse(startTimeRaw, timeZone: timeZone) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidTimestamp(field: "start_time", value: startTimeRaw)), drops)
    }
    guard let endDate = HevyTimestamp.parse(endTimeRaw, timeZone: timeZone) else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidTimestamp(field: "end_time", value: endTimeRaw)), drops)
    }
    // Finding 6.2: an end that precedes its start can never describe a
    // real logged set, whatever combination of otherwise-valid timestamps
    // produced it.
    guard endDate >= startDate else {
        return .malformed(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .endBeforeStart), drops)
    }

    let isWarmup = setTypeRaw == "warmup"

    return .row(DecodedRow(
        title: title,
        startDate: startDate,
        endDate: endDate,
        exerciseTitle: exerciseTitle,
        weight: weight,
        reps: reps,
        isWarmup: isWarmup,
        description: header.value("description", in: fields)
    ), drops)
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
        normalizedTitle = CatalogSeed.normalizedMatchKey(firstRow.exerciseTitle)
        displayName = firstRow.exerciseTitle
        rows = [firstRow]
    }

    func append(_ row: DecodedRow) {
        rows.append(row)
    }
}

/// One dropped-and-counted disagreement between rows grouped into the same
/// session (finding 4.5): a later row's `end_time` or nonempty description
/// that disagrees with the value an earlier row already established. The
/// disagreeing row's *set* is still imported into the session either way —
/// only the conflicting session-level value itself is dropped, since
/// Hevy's convention is that every row of a session repeats the same
/// session-level values, and a disagreement is far more likely to be one
/// bad row than a signal that the session should be split or truncated.
struct SessionMetadataConflict: Equatable {
    var endTime = false
    var description = false

    var droppedValueCount: Int {
        (endTime ? 1 : 0) + (description ? 1 : 0)
    }
}

/// Accumulates every row belonging to one session (grouped by title +
/// canonical start instant, spec §8) as it's encountered, preserving file
/// order.
final class SessionAccumulator {
    let title: String
    let startDate: Date
    let endDate: Date
    /// First non-empty `description` seen for this session; Hevy repeats
    /// the same value on every row of a session, so "first wins" is
    /// equivalent to "the value" in practice — see `SessionMetadataConflict`
    /// for what happens when a later row disagrees.
    private(set) var description: String?
    private(set) var itemRuns: [ItemRun] = []

    init(title: String, startDate: Date, endDate: Date, description: String?) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.description = description
    }

    /// Appends `row` to this session, grouping it into the current
    /// contiguous exercise run or starting a new one, and reports any
    /// session-level metadata conflict found (finding 4.5).
    @discardableResult
    func append(_ row: DecodedRow) -> SessionMetadataConflict {
        var conflict = SessionMetadataConflict()

        if row.endDate != endDate {
            conflict.endTime = true
        }
        if let rowDescription = row.description {
            if let existing = description {
                if existing != rowDescription { conflict.description = true }
            } else {
                description = rowDescription
            }
        }

        let normalized = CatalogSeed.normalizedMatchKey(row.exerciseTitle)
        if let last = itemRuns.last, last.normalizedTitle == normalized {
            last.append(row)
        } else {
            itemRuns.append(ItemRun(firstRow: row))
        }

        return conflict
    }
}
