// SPDX-License-Identifier: GPL-3.0-or-later
//
// Exercises spec §8 acceptance criteria #1 and #2 (this task's acceptance):
//   1. Fixture CSVs cover bodyweight rows -> 0 kg, warmups, cardio-row
//      skipping with correct counts, malformed-row tolerance, alias +
//      unmatched->custom paths.
//   2. Double-import test: same file twice -> zero duplicates (deterministic
//      UUID upsert). Overlapping newer export -> only new sessions added.
// Sets/sessions from `BurlyFixtures` cover the scenarios its generator
// already models (bodyweight, warmups, malformed rows, alias/custom
// exercise names via hand-built `FixtureSession`s). Cardio/RPE/superset/
// non-standard-set-type scenarios use hand-written CSV text against the
// fuller, publicly-documented real Hevy column set (see HevyCSVSchema.swift
// and HevyTimestamp.swift doc comments) since BurlyFixtures.HevyCSVGenerator
// only models the minimal 8-column subset.
import BurlyCore
import BurlyFixtures
import Foundation
import Testing
@testable import BurlyImport

@Suite("HevyCSVImporter — spec §8 acceptance #1 and #2")
struct HevyCSVImporterTests {
    private static let referenceStartDate = CivilDate(year: 2025, month: 6, day: 15)

    private func loadCatalog() throws -> CatalogSeed {
        try CatalogSeed.loadBundled()
    }

    private func start(dayOffset: Int = 0, minuteOfDay: Int = 480) -> CivilDateTime {
        CivilDateTime(dayCount: Self.referenceStartDate.dayCount + dayOffset, minuteOfDay: minuteOfDay)
    }

    // MARK: - Bodyweight / warmup (acceptance #1)

    @Test("a 0/empty weight_kg column maps to the 0 kg bodyweight convention")
    func bodyweightRowsMapToZeroKg() throws {
        let session = FixtureSession(
            title: "Pull Day",
            start: start(),
            durationMinutes: 30,
            exercises: [
                FixtureExercise(title: "Quantum Leg Curl", muscle: "Legs", sets: [
                    FixtureSet(weightKg: 0, reps: 10)
                ])
            ]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        let set = try #require(result.sessions.first?.items.first?.sets.first)
        #expect(set.weightKg == 0)
        #expect(set.reps == 10)
    }

    @Test("set_type \"warmup\" maps to isWarmup true; \"normal\" maps to false")
    func warmupFlagMapsCorrectly() throws {
        let session = FixtureSession(
            title: "Push Day",
            start: start(),
            durationMinutes: 30,
            exercises: [
                FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [
                    FixtureSet(weightKg: 40, reps: 8, isWarmup: true),
                    FixtureSet(weightKg: 80, reps: 5, isWarmup: false)
                ])
            ]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        let sets = try #require(result.sessions.first?.items.first?.sets)
        #expect(sets.count == 2)
        #expect(sets[0].isWarmup == true)
        #expect(sets[1].isWarmup == false)
    }

    // MARK: - Alias + unmatched->custom paths (acceptance #1)

    @Test("a Hevy-alias-table exercise title resolves to the curated catalog exercise, no custom created")
    func aliasPathResolvesToCatalogExercise() throws {
        let catalog = try loadCatalog()
        let expectedID = try #require(catalog.exerciseID(forHevyAlias: "Bench Press (Barbell)"))

        let session = FixtureSession(
            title: "Push Day", start: start(), durationMinutes: 30,
            exercises: [FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [FixtureSet(weightKg: 80, reps: 5)])]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: catalog)

        #expect(result.sessions.first?.items.first?.exerciseID == expectedID)
        #expect(result.newExercises.isEmpty)
        #expect(result.summary.exercisesMatched == 1)
        #expect(result.summary.exercisesCreatedAsCustom == 0)
    }

    @Test("alias matching is case-insensitive")
    func aliasPathIsCaseInsensitive() throws {
        let catalog = try loadCatalog()
        let expectedID = try #require(catalog.exerciseID(forHevyAlias: "Bench Press (Barbell)"))

        let session = FixtureSession(
            title: "Push Day", start: start(), durationMinutes: 30,
            exercises: [FixtureExercise(title: "BENCH PRESS (BARBELL)", muscle: "Chest", sets: [FixtureSet(weightKg: 80, reps: 5)])]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: catalog)

        #expect(result.sessions.first?.items.first?.exerciseID == expectedID)
        #expect(result.newExercises.isEmpty)
    }

    @Test("an exercise title matching neither alias nor catalog name creates a custom exercise, never dropped")
    func unmatchedExerciseCreatesCustom() throws {
        let session = FixtureSession(
            title: "Push Day", start: start(), durationMinutes: 30,
            exercises: [FixtureExercise(title: "Quantum Leg Curl", muscle: "Legs", sets: [FixtureSet(weightKg: 20, reps: 12)])]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        let created = try #require(result.newExercises.first)
        #expect(result.newExercises.count == 1)
        #expect(created.name == "Quantum Leg Curl")
        #expect(created.origin == .hevyImport)
        #expect(created.muscleGroups.isEmpty)
        #expect(created.needsNaming == false)
        #expect(result.sessions.first?.items.first?.exerciseID == created.id)
        #expect(result.summary.exercisesCreatedAsCustom == 1)
        #expect(result.summary.exercisesMatched == 0)
    }

    @Test("the same unmatched exercise name across multiple sessions in one file gets one custom exercise, not several")
    func unmatchedExerciseDeduplicatesAcrossSessions() throws {
        let sessions = [
            FixtureSession(title: "Day A", start: start(dayOffset: 0), durationMinutes: 30, exercises: [
                FixtureExercise(title: "Quantum Leg Curl", muscle: "Legs", sets: [FixtureSet(weightKg: 20, reps: 12)])
            ]),
            FixtureSession(title: "Day B", start: start(dayOffset: 2), durationMinutes: 30, exercises: [
                FixtureExercise(title: "Quantum Leg Curl", muscle: "Legs", sets: [FixtureSet(weightKg: 22, reps: 10)])
            ])
        ]
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.newExercises.count == 1)
        let onlyID = result.newExercises[0].id
        #expect(result.sessions[0].items[0].exerciseID == onlyID)
        #expect(result.sessions[1].items[0].exerciseID == onlyID)
    }

    // MARK: - Malformed-row tolerance (acceptance #1)

    @Test("malformedRowRate 1.0 accounts for every row as malformed and never throws")
    func fullyMalformedFileIsFullyAccounted() throws {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 40, sessionCount: 5, spanDays: 30, startDate: Self.referenceStartDate
        )
        let totalRows = sessions.flatMap(\.exercises).flatMap(\.sets).count
        let csv = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 1.0, seed: 99)

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == totalRows)
        #expect(result.sessions.isEmpty)
        #expect(result.summary.setsImported == 0)
    }

    @Test("a partially malformed file accounts for every row as either imported or malformed, and does not abort")
    func partiallyMalformedFileAccountsForEveryRow() throws {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 41, sessionCount: 8, spanDays: 30, startDate: Self.referenceStartDate
        )
        let totalRows = sessions.flatMap(\.exercises).flatMap(\.sets).count
        let csv = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 0.5, seed: 7)

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        // No cardio rows exist in this fixture, so every non-malformed row
        // becomes exactly one imported set: nothing vanishes unaccounted.
        #expect(result.summary.malformedRowCount + result.summary.setsImported == totalRows)
        #expect(result.summary.malformedRowCount > 0)
        #expect(result.summary.setsImported > 0)
    }

    @Test("malformed rows never abort the whole import — only an unrecognizable header does")
    func malformedRowsDoNotAbort() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let good = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let wrongColumnCount = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",2,\"normal\",80"
        let badWeight = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",3,\"normal\",N/A,5"
        let csv = [header, good, wrongColumnCount, badWeight].joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.malformedRowCount == 2)
        #expect(result.summary.malformedRows.map(\.rowNumber).sorted() == [3, 4])
    }

    // MARK: - Cardio-row skipping (acceptance #1)

    private static let extendedHeader = "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe"

    @Test("distance/duration-only rows are skipped in full and counted, without corrupting the surrounding strength sets")
    func cardioRowsAreSkippedAndCounted() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"normal",80,5,,,"# ,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Running",,"",1,"normal",,,5.0,1800,"# ,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Rowing Machine",,"",2,"normal",,,,600,"# ,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",3,"normal",85,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.cardioRowsSkipped == 2)
        #expect(result.summary.setsImported == 2)
        #expect(result.summary.malformedRowCount == 0)
        // The two surviving strength rows are contiguous once the cardio
        // rows between them are filtered out, so they land in one item.
        #expect(result.sessions.first?.items.count == 1)
        #expect(result.sessions.first?.items.first?.sets.count == 2)
    }

    // MARK: - RPE / superset / non-standard set_type accounting (acceptance #1)

    @Test("a present rpe value is dropped and counted, but the set itself is still imported")
    func rpeValuesAreDroppedAndCounted() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"normal",80,5,,,8.5"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",1,"normal",80,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.rpeValuesDropped == 1)
        #expect(result.summary.setsImported == 2)
    }

    @Test("a present superset_id is dropped and counted, but the set itself is still imported as independent")
    func supersetGroupingIsDroppedAndCounted() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)","grp-1","",0,"normal",80,5,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Overhead Press","grp-1","",1,"normal",40,8,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.supersetRowsDropped == 2)
        #expect(result.summary.setsImported == 2)
    }

    @Test("failure and dropset set_type markers import as normal sets and are counted, never silently coerced")
    func failureAndDropsetMarkersFlattenToNormal() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"failure",80,5,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",1,"dropset",60,8,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",2,"normal",80,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        let sets = try #require(result.sessions.first?.items.first?.sets)
        #expect(sets.allSatisfy { $0.isWarmup == false })
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 2)
    }

    @Test("an exercise_notes value is dropped and counted")
    func exerciseNotesAreDroppedAndCounted() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"felt heavy",0,"normal",80,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.setsImported == 1)
    }

    @Test("a session-level description is captured as the session's notes, not dropped")
    func descriptionMapsToSessionNotes() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Felt great today","Bench Press (Barbell)",,"",0,"normal",80,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.sessions.first?.notes == "Felt great today")
    }

    // MARK: - Repeated (non-contiguous) exercise handling

    @Test("the same exercise logged twice non-contiguously in a session becomes two separate items with distinct IDs")
    func nonContiguousRepeatedExerciseBecomesTwoItems() throws {
        let session = FixtureSession(
            title: "Full Body", start: start(), durationMinutes: 45,
            exercises: [
                FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [FixtureSet(weightKg: 80, reps: 5)]),
                FixtureExercise(title: "Squat (Barbell)", muscle: "Legs", sets: [FixtureSet(weightKg: 100, reps: 5)]),
                FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [FixtureSet(weightKg: 82.5, reps: 4)])
            ]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        let items = try #require(result.sessions.first?.items)
        #expect(items.count == 3)
        #expect(items[0].exerciseID == items[2].exerciseID) // same exercise
        #expect(items[0].id != items[2].id) // but distinct items/IDs
    }

    // MARK: - Determinism / upsert-shaped re-import (acceptance #2)

    @Test("re-parsing the same file twice produces an identical result, including every ID")
    func sameFileReimportedProducesIdenticalResult() throws {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 12, sessionCount: 10, spanDays: 45, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(warmupSetProbability: 0.5, repeatedExerciseProbability: 0.3)
        )
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        let catalog = try loadCatalog()

        let first = try HevyCSVImporter.parse(csv: csv, catalog: catalog)
        let second = try HevyCSVImporter.parse(csv: csv, catalog: catalog)

        #expect(first == second)
        #expect(!first.sessions.isEmpty)
    }

    @Test("an overlapping newer export reuses the same session ID for a repeated workout and only adds new sessions")
    func overlappingExportReusesSessionIDsForSharedWorkouts() throws {
        let catalog = try loadCatalog()
        let sessionA1 = FixtureSession(
            title: "Push Day", start: start(dayOffset: 0), durationMinutes: 45,
            exercises: [FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [FixtureSet(weightKg: 80, reps: 5)])]
        )
        let sessionA2 = FixtureSession(
            title: "Pull Day", start: start(dayOffset: 2), durationMinutes: 45,
            exercises: [FixtureExercise(title: "Squat (Barbell)", muscle: "Legs", sets: [FixtureSet(weightKg: 100, reps: 5)])]
        )
        let sessionA3 = FixtureSession(
            title: "Leg Day", start: start(dayOffset: 5), durationMinutes: 45,
            exercises: [FixtureExercise(title: "Deadlift (Barbell)", muscle: "Legs", sets: [FixtureSet(weightKg: 140, reps: 3)])]
        )

        let fileA = HevyCSVGenerator.generate(sessions: [sessionA1, sessionA2])
        // "Overlapping newer export": repeats sessionA2 byte-for-byte and adds a genuinely new session.
        let fileB = HevyCSVGenerator.generate(sessions: [sessionA2, sessionA3])

        let resultA = try HevyCSVImporter.parse(csv: fileA, catalog: catalog)
        let resultB = try HevyCSVImporter.parse(csv: fileB, catalog: catalog)

        #expect(resultA.sessions.count == 2)
        #expect(resultB.sessions.count == 2)

        let sharedIDFromA = resultA.sessions[1].id // sessionA2, 2nd in fileA
        let sharedIDFromB = resultB.sessions[0].id // sessionA2, 1st in fileB
        #expect(sharedIDFromA == sharedIDFromB)

        let newIDFromB = resultB.sessions[1].id // sessionA3
        #expect(!resultA.sessions.map(\.id).contains(newIDFromB))
    }

    // MARK: - Hostile input hardening

    @Test("invalid UTF-8 bytes throw a typed encoding error instead of crashing or silently corrupting text")
    func invalidEncodingThrowsTypedError() {
        let brokenBytes = Data([0xFF, 0xFE, 0x80, 0x80, 0x00, 0x01])
        #expect(throws: HevyImportError.invalidEncoding) {
            _ = try HevyCSVImporter.parse(csvData: brokenBytes, catalog: try loadCatalog())
        }
    }

    @Test("a header missing a required column aborts the whole import with a typed error")
    func unrecognizedHeaderAborts() {
        let csv = "title,start_time,end_time,exercise_title,set_type,weight_kg\n" +
            "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",\"normal\",80\n"

        #expect(throws: HevyImportError.unrecognizedHeader(missingColumns: ["reps"])) {
            _ = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        }
    }

    @Test("an empty file aborts as an unrecognized header rather than a crash or a silent empty result")
    func emptyFileAbortsAsUnrecognizedHeader() {
        #expect(throws: (any Error).self) {
            _ = try HevyCSVImporter.parse(csv: "", catalog: try loadCatalog())
        }
    }

    @Test("a negative weight is rejected and accounted, never silently coerced to a valid weight")
    func negativeWeightIsMalformed() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV(weightField: "-50")
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.setsImported == 0)
    }

    @Test("NaN and Infinity weight text are rejected, not silently treated as a number")
    func nanAndInfinityWeightAreMalformed() throws {
        let nanCSV = HevyCSVGeneratorTestSupport.singleRowCSV(weightField: "NaN")
        let infCSV = HevyCSVGeneratorTestSupport.singleRowCSV(weightField: "Infinity")

        let nanResult = try HevyCSVImporter.parse(csv: nanCSV, catalog: try loadCatalog())
        let infResult = try HevyCSVImporter.parse(csv: infCSV, catalog: try loadCatalog())

        #expect(nanResult.summary.malformedRowCount == 1)
        #expect(infResult.summary.malformedRowCount == 1)
    }

    @Test("non-numeric weight garbage is rejected")
    func garbageWeightIsMalformed() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV(weightField: "eighty")
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        #expect(result.summary.malformedRowCount == 1)
    }

    @Test("negative and overflowing reps are rejected")
    func negativeAndOverflowingRepsAreMalformed() throws {
        let negative = HevyCSVGeneratorTestSupport.singleRowCSV(repsField: "-3")
        let overflow = HevyCSVGeneratorTestSupport.singleRowCSV(repsField: "999999999999999999999999999")

        let negativeResult = try HevyCSVImporter.parse(csv: negative, catalog: try loadCatalog())
        let overflowResult = try HevyCSVImporter.parse(csv: overflow, catalog: try loadCatalog())

        #expect(negativeResult.summary.malformedRowCount == 1)
        #expect(overflowResult.summary.malformedRowCount == 1)
    }

    @Test("a garbage timestamp is rejected with the offending field named")
    func garbageTimestampIsMalformed() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV(startTimeField: "not-a-date")
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        let malformed = try #require(result.summary.malformedRows.first)
        #expect(malformed.reason == .invalidTimestamp(field: "start_time", value: "not-a-date"))
    }

    @Test("summary counts are always internally consistent with the returned sessions and exercises")
    func summaryCountsAreInternallyConsistent() throws {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 55, sessionCount: 15, spanDays: 60, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(warmupSetProbability: 0.4, repeatedExerciseProbability: 0.2)
        )
        let csv = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 0.2, seed: 3)
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.sessionsImported == result.sessions.count)
        #expect(result.summary.setsImported == result.sessions.flatMap(\.items).flatMap(\.sets).count)
        #expect(result.summary.exercisesCreatedAsCustom == result.newExercises.count)
    }
}

/// Tiny hand-written single-row CSV builder for hostile-input tests that
/// need to corrupt exactly one field without going through the shared
/// fixture generator (which only ever emits well-formed numeric text).
private enum HevyCSVGeneratorTestSupport {
    static func singleRowCSV(
        startTimeField: String = "2025-06-15 08:00:00",
        weightField: String = "80",
        repsField: String = "5"
    ) -> String {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let row = "\"Push Day\",\"\(startTimeField)\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",\(weightField),\(repsField)"
        return header + "\n" + row + "\n"
    }
}
