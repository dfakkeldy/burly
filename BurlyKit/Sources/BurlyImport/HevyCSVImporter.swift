// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyCSVImporter
//
// Top-level entry point (spec §8): tokenize -> validate the header -> decode
// each data row -> group rows into sessions/exercise-runs/sets -> resolve
// exercise names against the catalog -> emit domain values plus a
// dropped-data summary. A single synchronous pass builds everything, so the
// summary can never disagree with the sessions/newExercises it describes
// (spec §8 acceptance #4).
//
// ID derivation (spec §8, "Deterministic UUID"): every ID below comes from
// `DeterministicUUID.v5`, hashing content that identifies the entity:
//   - session:  title + start_time, exactly as they appear in the file
//   - exercise: the normalized (lowercased, trimmed) unmatched exercise
//               title, independent of which session it first appears in
//   - item:     the owning session's ID + the resolved exercise's ID + how
//               many earlier runs of that same exercise this session
//               already had (see "repeated exercise" below)
//   - set:      the owning item's ID + the set's 0-based position in that
//               item
// Re-parsing the same file — or a newer, overlapping export that repeats
// some of the same workouts — reproduces identical IDs for the identical
// underlying data at every level, not just the session. That's what lets a
// later persistence task upsert instead of duplicate.
//
// Set ordering deliberately ignores the CSV's own `set_index` column and
// uses row order instead (see HevyCSVSchema's doc comment): a real export's
// numbering convention is unverified pending m7-03.
//
// "Repeated exercise" handling: rows are grouped into a new exercise-run
// whenever the (case-insensitive) exercise title changes from the
// immediately preceding row within the same session — so the same exercise
// logged twice non-contiguously in one session (e.g. two separate blocks)
// becomes two separate `SessionItemData`s, matching how Hevy actually
// writes such a session out (each logged instance is its own contiguous
// block of rows), rather than merging them into one.
import BurlyCore
import Foundation

public enum HevyCSVImporter {
    /// Convenience overload for a file picker handing back raw bytes.
    /// Non-UTF-8 input throws `.invalidEncoding` rather than crashing or
    /// silently substituting replacement characters into what would then
    /// look like valid (but wrong) exercise names.
    public static func parse(csvData: Data, catalog: CatalogSeed) throws -> HevyImportResult {
        guard let text = String(data: csvData, encoding: .utf8) else {
            throw HevyImportError.invalidEncoding
        }
        return try parse(csv: text, catalog: catalog)
    }

    public static func parse(csv: String, catalog: CatalogSeed) throws -> HevyImportResult {
        let rows = CSVTokenizer.rows(in: csv)
        guard let headerFields = rows.first else {
            throw HevyImportError.unrecognizedHeader(missingColumns: HevyCSVSchema.requiredColumns)
        }

        let header = HevyCSVHeader(fields: headerFields)
        let missingColumns = header.missingRequiredColumns
        guard missingColumns.isEmpty else {
            throw HevyImportError.unrecognizedHeader(missingColumns: missingColumns)
        }

        let catalogNameIndex = Dictionary(
            catalog.exercises.map { (key: $0.name.lowercased(), value: $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var malformedRows: [MalformedRow] = []
        var cardioRowsSkipped = 0
        var rpeValuesDropped = 0
        var supersetRowsDropped = 0
        var nonStandardSetTypeMarkersFlattened = 0
        var exerciseNotesDropped = 0

        var sessionOrder: [String] = []
        var accumulators: [String: SessionAccumulator] = [:]

        for (offset, fields) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2 // header occupies row 1
            switch decodeRow(fields: fields, header: header, expectedColumnCount: header.columnCount, rowNumber: rowNumber) {
            case .malformed(let malformed):
                malformedRows.append(malformed)

            case .cardio:
                cardioRowsSkipped += 1

            case .row(let decoded):
                if decoded.hasRPE { rpeValuesDropped += 1 }
                if decoded.hasSupersetID { supersetRowsDropped += 1 }
                if decoded.hasExerciseNotes { exerciseNotesDropped += 1 }
                if decoded.nonStandardSetType { nonStandardSetTypeMarkersFlattened += 1 }

                let sessionKey = decoded.title + "\u{1}" + decoded.startTimeRaw
                if accumulators[sessionKey] == nil {
                    sessionOrder.append(sessionKey)
                    accumulators[sessionKey] = SessionAccumulator(
                        title: decoded.title,
                        startTimeRaw: decoded.startTimeRaw,
                        startDate: decoded.startDate,
                        endDate: decoded.endDate,
                        description: decoded.description
                    )
                }
                accumulators[sessionKey]?.append(decoded)
            }
        }

        var newExercisesByName: [String: ExerciseData] = [:]
        // Tracks first-appearance order separately from the dictionary
        // above: Dictionary iteration order is not guaranteed stable even
        // across two identically-constructed dictionaries in the same
        // process (confirmed empirically while building this importer —
        // see HANDOFF for the repro), so `Array(newExercisesByName.values)`
        // would silently break the "same file re-imported -> identical
        // result" guarantee (spec §8) by reordering `newExercises` between
        // runs despite every ID staying the same.
        var newExerciseOrder: [String] = []
        var matchedExerciseIDs = Set<UUID>()
        var sessions: [SessionData] = []
        var setsImported = 0

        for key in sessionOrder {
            guard let accumulator = accumulators[key] else { continue }
            let sessionID = DeterministicUUID.v5(
                name: "session\u{1}" + accumulator.title + "\u{1}" + accumulator.startTimeRaw
            )

            var items: [SessionItemData] = []
            var occurrenceCounts: [String: Int] = [:]

            for (order, run) in accumulator.itemRuns.enumerated() {
                let exerciseID = resolveExercise(
                    displayName: run.displayName,
                    normalizedName: run.normalizedTitle,
                    catalog: catalog,
                    catalogNameIndex: catalogNameIndex,
                    matchedExerciseIDs: &matchedExerciseIDs,
                    newExercisesByName: &newExercisesByName,
                    newExerciseOrder: &newExerciseOrder
                )

                let occurrence = occurrenceCounts[run.normalizedTitle, default: 0]
                occurrenceCounts[run.normalizedTitle] = occurrence + 1
                let itemID = DeterministicUUID.v5(
                    name: "item\u{1}" + sessionID.uuidString + "\u{1}" + exerciseID.uuidString + "\u{1}" + String(occurrence)
                )

                var sets: [SetRecordData] = []
                sets.reserveCapacity(run.rows.count)
                for (position, decoded) in run.rows.enumerated() {
                    let setID = DeterministicUUID.v5(
                        name: "set\u{1}" + itemID.uuidString + "\u{1}" + String(position)
                    )
                    sets.append(SetRecordData(
                        id: setID,
                        order: position,
                        weight: decoded.weight,
                        reps: decoded.reps,
                        isWarmup: decoded.isWarmup,
                        completedAt: accumulator.startDate
                    ))
                }
                setsImported += sets.count
                items.append(SessionItemData(id: itemID, exerciseID: exerciseID, order: order, sets: sets))
            }

            sessions.append(SessionData(
                id: sessionID,
                startedAt: accumulator.startDate,
                endedAt: accumulator.endDate,
                state: .logged,
                origin: .hevyImport,
                items: items,
                notes: accumulator.description
            ))
        }

        let summary = HevyImportSummary(
            sessionsImported: sessions.count,
            setsImported: setsImported,
            exercisesMatched: matchedExerciseIDs.count,
            exercisesCreatedAsCustom: newExercisesByName.count,
            cardioRowsSkipped: cardioRowsSkipped,
            rpeValuesDropped: rpeValuesDropped,
            supersetRowsDropped: supersetRowsDropped,
            nonStandardSetTypeMarkersFlattened: nonStandardSetTypeMarkersFlattened,
            exerciseNotesDropped: exerciseNotesDropped,
            malformedRows: malformedRows
        )

        return HevyImportResult(
            sessions: sessions,
            newExercises: newExerciseOrder.compactMap { newExercisesByName[$0] },
            summary: summary
        )
    }

    /// Matches `displayName` against the alias table first (spec §8's
    /// "curated alias table"), then a direct case-insensitive catalog name
    /// match, then falls back to an already-created custom exercise from
    /// earlier in this same file, and only creates a new one if none of
    /// those hit. Never returns without an ID — an unmatched name is never
    /// silently dropped (spec §8).
    private static func resolveExercise(
        displayName: String,
        normalizedName: String,
        catalog: CatalogSeed,
        catalogNameIndex: [String: UUID],
        matchedExerciseIDs: inout Set<UUID>,
        newExercisesByName: inout [String: ExerciseData],
        newExerciseOrder: inout [String]
    ) -> UUID {
        if let aliasID = catalog.exerciseID(forHevyAlias: displayName) {
            matchedExerciseIDs.insert(aliasID)
            return aliasID
        }
        if let nameID = catalogNameIndex[normalizedName] {
            matchedExerciseIDs.insert(nameID)
            return nameID
        }
        if let existing = newExercisesByName[normalizedName] {
            return existing.id
        }

        let id = DeterministicUUID.v5(name: "exercise\u{1}" + normalizedName)
        newExercisesByName[normalizedName] = ExerciseData(
            id: id,
            name: displayName,
            // No tags: guessing muscle groups for an exercise Burly's
            // catalog doesn't know would put invented data in the
            // muscle-split stat (§7) — mirrors the same reasoning as the
            // watch's placeholder-exercise path (SessionMutator).
            muscleGroups: [],
            origin: .hevyImport,
            needsNaming: false
        )
        newExerciseOrder.append(normalizedName)
        return id
    }
}
