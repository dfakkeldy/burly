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
//   - session:  title + a canonical (locale/format-independent) rendering
//               of the parsed start instant — NOT the raw accepted input
//               lexeme, so the same instant exported once as
//               "yyyy-MM-dd HH:mm:ss" and again as "d MMM yyyy, HH:mm"
//               hashes to the same session ID (m7-01 review finding 2.2;
//               see `HevyTimestamp.canonicalKey`).
//   - exercise: the catalog/lookup-normalized (NFC + locale-independent
//               case-folded, see `CatalogSeed.normalizedMatchKey`)
//               unmatched exercise title, independent of which session it
//               first appears in.
//   - item:     the owning session's ID + the RESOLVED exercise's ID + how
//               many earlier runs of that same *resolved exercise* this
//               session already had (see "repeated exercise" below —
//               finding 2.1: keyed by resolved ID, not raw title, so two
//               differently-spelled aliases of the same exercise can't
//               collide onto the same occurrence number).
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
// whenever the (normalized) exercise title changes from the immediately
// preceding row within the same session — so the same exercise logged
// twice non-contiguously in one session (e.g. two separate blocks) becomes
// two separate `SessionItemData`s, matching how Hevy actually writes such a
// session out (each logged instance is its own contiguous block of rows),
// rather than merging them into one.
import BurlyCore
import Foundation

public enum HevyCSVImporter {
    /// Convenience overload for a file picker handing back raw bytes.
    ///
    /// A single invalid UTF-8 byte anywhere in the file must not abort the
    /// whole import (m7-01 review finding 1.1) — only an unrecognizable
    /// header may do that. This tries a strict UTF-8 decode first (the
    /// common, zero-cost-difference case for a well-formed file); only if
    /// that fails does it fall back to a lossy decode (invalid byte
    /// sequences become U+FFFD) so every otherwise-valid row's text
    /// survives intact. The per-row loop below then accounts for whichever
    /// row still carries a replacement character as malformed
    /// (`.invalidUTF8`) instead of importing corrupted text as if it were
    /// a real value; a header corrupted enough to be unrecognizable still
    /// aborts via `.unrecognizedHeader`, since a replacement character
    /// breaks its exact required-column-name match.
    public static func parse(
        csvData: Data,
        catalog: CatalogSeed,
        timeZone: TimeZone = HevyTimestamp.defaultTimeZone
    ) throws -> HevyImportResult {
        let text: String
        if let strict = String(data: csvData, encoding: .utf8) {
            text = strict
        } else {
            text = String(decoding: csvData, as: UTF8.self)
        }
        return try parse(csv: text, catalog: catalog, timeZone: timeZone)
    }

    /// - Parameter timeZone: How to interpret Hevy's timezone-less
    ///   wall-clock timestamps (finding 6.1). Defaults to
    ///   `HevyTimestamp.defaultTimeZone` (UTC), this module's original
    ///   assumption — now an explicit, overridable default instead of a
    ///   silent one. Pass the export device's real timezone when it's
    ///   known to avoid a multi-hour shift versus the wall-clock time Hevy
    ///   actually displayed.
    public static func parse(
        csv: String,
        catalog: CatalogSeed,
        timeZone: TimeZone = HevyTimestamp.defaultTimeZone
    ) throws -> HevyImportResult {
        // Finding 1.2: strip exactly one leading BOM before header
        // resolution — otherwise the first header column's key retains
        // the BOM scalar and a validly-named "title" column is rejected
        // as missing.
        var csv = csv
        if csv.hasPrefix("\u{FEFF}") {
            csv.removeFirst()
        }

        let tokenizedRows = CSVTokenizer.rows(in: csv)
        guard let first = tokenizedRows.first, case .fields(let headerFields) = first else {
            throw HevyImportError.unrecognizedHeader(missingColumns: HevyCSVSchema.requiredColumns)
        }

        let header = HevyCSVHeader(fields: headerFields)
        let missingColumns = header.missingRequiredColumns
        guard missingColumns.isEmpty else {
            throw HevyImportError.unrecognizedHeader(missingColumns: missingColumns)
        }

        let catalogNameIndex = Dictionary(
            catalog.exercises.map { (key: CatalogSeed.normalizedMatchKey($0.name), value: $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var malformedRows: [MalformedRow] = []
        var cardioRowsSkipped = 0
        var rpeValuesDropped = 0
        var supersetRowsDropped = 0
        var nonStandardSetTypeMarkersFlattened = 0
        var exerciseNotesDropped = 0
        var setIndexValuesDropped = 0
        var unknownColumnValuesDropped = 0
        var conflictingSessionMetadataDropped = 0

        func applyDrops(_ drops: RowMetadataDrops) {
            if drops.hasRPE { rpeValuesDropped += 1 }
            if drops.hasSupersetID { supersetRowsDropped += 1 }
            if drops.hasExerciseNotes { exerciseNotesDropped += 1 }
            if drops.hasSetIndexValue { setIndexValuesDropped += 1 }
            if drops.nonStandardSetType { nonStandardSetTypeMarkersFlattened += 1 }
            unknownColumnValuesDropped += drops.unknownColumnValueCount
        }

        var sessionOrder: [String] = []
        var accumulators: [String: SessionAccumulator] = [:]

        for (offset, tokenizedRow) in tokenizedRows.dropFirst().enumerated() {
            let rowNumber = offset + 2 // header occupies row 1

            let fields: [String]
            switch tokenizedRow {
            case .blank:
                malformedRows.append(MalformedRow(rowNumber: rowNumber, rawFields: [], reason: .blankRow))
                continue
            case .unterminatedQuote:
                malformedRows.append(MalformedRow(rowNumber: rowNumber, rawFields: [], reason: .unterminatedQuote))
                continue
            case .strayQuote:
                malformedRows.append(MalformedRow(rowNumber: rowNumber, rawFields: [], reason: .strayQuoteInField))
                continue
            case .oversizedRecord:
                malformedRows.append(MalformedRow(
                    rowNumber: rowNumber, rawFields: [],
                    reason: .oversizedRecord(limitScalars: CSVTokenizer.maxFieldLength)
                ))
                continue
            case .fields(let rowFields):
                fields = rowFields
            }

            // Finding 1.1: any field that still carries a replacement
            // character couldn't be decoded even under the lossy fallback
            // above — report the row as malformed instead of importing
            // corrupted text as if it were a real value.
            if fields.contains(where: { $0.contains("\u{FFFD}") }) {
                malformedRows.append(MalformedRow(rowNumber: rowNumber, rawFields: fields, reason: .invalidUTF8))
                continue
            }

            switch decodeRow(fields: fields, header: header, expectedColumnCount: header.columnCount, rowNumber: rowNumber, timeZone: timeZone) {
            case .malformed(let malformed, let drops):
                malformedRows.append(malformed)
                applyDrops(drops)

            case .cardio(let drops):
                cardioRowsSkipped += 1
                applyDrops(drops)

            case .row(let decoded, let drops):
                applyDrops(drops)

                let sessionKey = decoded.title + "\u{1}" + HevyTimestamp.canonicalKey(for: decoded.startDate)
                if accumulators[sessionKey] == nil {
                    sessionOrder.append(sessionKey)
                    accumulators[sessionKey] = SessionAccumulator(
                        title: decoded.title,
                        startDate: decoded.startDate,
                        endDate: decoded.endDate,
                        description: decoded.description
                    )
                }
                let conflict = accumulators[sessionKey]!.append(decoded)
                conflictingSessionMetadataDropped += conflict.droppedValueCount
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
                name: "session\u{1}" + accumulator.title + "\u{1}" + HevyTimestamp.canonicalKey(for: accumulator.startDate)
            )

            var items: [SessionItemData] = []
            // Finding 2.1: keyed by the RESOLVED exercise ID, not the raw
            // normalized title — two differently-spelled aliases of the
            // same exercise (e.g. "Bench Press (Barbell)" and "Barbell
            // Bench Press") resolve to the same ID and must therefore
            // share one occurrence sequence, not each start their own at 0
            // and collide onto identical item/set UUIDs.
            var occurrenceCounts: [UUID: Int] = [:]

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

                let occurrence = occurrenceCounts[exerciseID, default: 0]
                occurrenceCounts[exerciseID] = occurrence + 1
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
            setIndexValuesDropped: setIndexValuesDropped,
            unknownColumnValuesDropped: unknownColumnValuesDropped,
            conflictingSessionMetadataDropped: conflictingSessionMetadataDropped,
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

        // Finding 7.1: `normalizedName` is NFC-normalized and
        // locale-independent case-folded (see `CatalogSeed
        // .normalizedMatchKey`), so two byte-different-but-canonically-
        // equivalent spellings of the same custom exercise name (e.g. NFC
        // vs NFD accents) hash to the same identity here.
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
