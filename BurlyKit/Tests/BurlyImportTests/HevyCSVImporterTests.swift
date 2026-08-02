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

    @Test("finding 1.1 — an invalid UTF-8 byte in one row does not abort the whole import; only that row is malformed")
    func invalidUTF8InOneRowDoesNotAbortImport() throws {
        // Pinning regression: the old importer decoded the whole file with
        // `String(data:encoding:.utf8)`, which returns `nil` the moment
        // ANY byte anywhere is invalid — aborting every otherwise-valid
        // row with `.invalidEncoding` instead of accounting for just the
        // one corrupted row.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let goodRow = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        var bytes = Data((header + "\n" + goodRow + "\n").utf8)
        // Append a second, otherwise well-formed row but with one invalid
        // UTF-8 byte spliced into the exercise title field.
        var brokenRow = Data("\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bad".utf8)
        brokenRow.append(0xFF) // invalid standalone UTF-8 byte
        brokenRow.append(Data("Row\",2,\"normal\",80,5\n".utf8))
        bytes.append(brokenRow)

        let result = try HevyCSVImporter.parse(csvData: bytes, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.malformedRows.first?.reason == .invalidUTF8)
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

    // MARK: - m7-01 adversarial review round 1 — blockers and majors

    @Test("finding 1.2 — a leading UTF-8 BOM is stripped before header resolution")
    func bomIsStrippedBeforeHeaderResolution() throws {
        // Pinning regression: without stripping, the first header key
        // retains the BOM scalar ("\u{FEFF}title"), so a validly-named
        // "title" column is rejected as missing and the whole import
        // throws `unrecognizedHeader`.
        let csv = "\u{FEFF}title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps\n" +
            "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5\n"
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        #expect(result.summary.setsImported == 1)
    }

    @Test("tokenizer-level malformed records (e.g. a blank interior line) surface as accounted malformed rows, not a thrown error")
    func tokenizerLevelMalformedRecordsSurfaceAsMalformedRows() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let good = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let csv = header + "\n" + "\n" + good + "\n" // blank interior record before the good row

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.malformedRows.first?.reason == .blankRow)
    }

    @Test("finding 2.1 — two different aliases of the same exercise in one session get distinct item/set IDs, not colliding ones")
    func twoAliasesOfSameExerciseInOneSessionGetDistinctIDs() throws {
        let catalog = try loadCatalog()
        // "Bench Press (Barbell)" is a curated Hevy alias for the catalog
        // exercise actually named "Barbell Bench Press" — both runs below
        // resolve to the identical catalog exercise ID.
        let session = FixtureSession(
            title: "Full Body", start: start(), durationMinutes: 45,
            exercises: [
                FixtureExercise(title: "Bench Press (Barbell)", muscle: "Chest", sets: [FixtureSet(weightKg: 80, reps: 5)]),
                FixtureExercise(title: "Squat (Barbell)", muscle: "Legs", sets: [FixtureSet(weightKg: 100, reps: 5)]),
                FixtureExercise(title: "Barbell Bench Press", muscle: "Chest", sets: [FixtureSet(weightKg: 82.5, reps: 4)])
            ]
        )
        let csv = HevyCSVGenerator.generate(sessions: [session])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: catalog)

        let items = try #require(result.sessions.first?.items)
        #expect(items.count == 3)
        #expect(items[0].exerciseID == items[2].exerciseID) // same resolved catalog exercise
        // Pinning regression: occurrence counting keyed by the raw
        // normalized title (two different strings) previously gave both
        // runs occurrence 0 against the same resolved exercise ID,
        // producing IDENTICAL item IDs (and colliding set IDs) here.
        #expect(items[0].id != items[2].id)
        let allSetIDs = items.flatMap(\.sets).map(\.id)
        #expect(Set(allSetIDs).count == allSetIDs.count)
    }

    @Test("finding 2.2 — both accepted timestamp formats for the same instant produce the same session ID")
    func bothTimestampFormatsForSameInstantProduceSameSessionID() throws {
        let catalog = try loadCatalog()
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let isoRow = "\"Push Day\",\"2025-12-22 08:00:00\",\"2025-12-22 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let hevyRow = "\"Push Day\",\"22 Dec 2025, 08:00\",\"22 Dec 2025, 08:30\",\"Bench Press (Barbell)\",1,\"normal\",80,5"

        let resultISO = try HevyCSVImporter.parse(csv: header + "\n" + isoRow + "\n", catalog: catalog)
        let resultHevy = try HevyCSVImporter.parse(csv: header + "\n" + hevyRow + "\n", catalog: catalog)

        // Pinning regression: hashing the raw accepted lexeme (rather than
        // a canonical parsed-instant representation) previously produced
        // two different session IDs for the same logical workout re-
        // exported in the other supported timestamp shape.
        let idISO = try #require(resultISO.sessions.first?.id)
        let idHevy = try #require(resultHevy.sessions.first?.id)
        #expect(idISO == idHevy)
    }

    @Test("finding 4.1 — a cardio row's rpe/superset/set_type/notes values are still counted as dropped")
    func cardioRowStillAccountsForOtherDroppedMetadata() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Running","grp-1","tough one",1,"dropset",,,5.0,1800,9"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        // Pinning regression: the cardio early-return only incremented
        // `cardioRowsSkipped`, leaving every other per-category counter at
        // zero even though this row's rpe/superset_id/exercise_notes/
        // set_type columns all had values.
        #expect(result.summary.cardioRowsSkipped == 1)
        #expect(result.summary.rpeValuesDropped == 1)
        #expect(result.summary.supersetRowsDropped == 1)
        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 1)
    }

    @Test("finding 4.2 — a malformed row's rpe/superset/notes/set_type values are still counted as dropped")
    func malformedRowStillAccountsForDroppedMetadata() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)","grp-1","tough one",1,"failure",80,not-a-number,,,9"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        // Pinning regression: required-field/reps validation returning
        // early left every metadata counter at zero even though the row's
        // rpe/superset_id/exercise_notes/set_type columns all had values.
        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.rpeValuesDropped == 1)
        #expect(result.summary.supersetRowsDropped == 1)
        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 1)
    }

    @Test("finding 4.3 — a nonempty value in a header column Burly doesn't recognize is counted as dropped, not silently ignored")
    func unknownColumnValueIsDroppedAndCounted() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps,tempo"
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5,\"3-1-1\""
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.unknownColumnValuesDropped == 1)
    }

    @Test("finding 4.4 — a present set_index value is discarded but visibly counted, not silently ignored")
    func setIndexValueIsDroppedAndCounted() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV()
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        #expect(result.summary.setIndexValuesDropped == 1)
    }

    @Test("finding 4.5 — a later row's conflicting end_time/description is dropped and counted, not silently ignored")
    func conflictingSessionMetadataIsDroppedAndCounted() throws {
        let rows = [
            Self.extendedHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Felt great","Bench Press (Barbell)",,"",0,"normal",80,5,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 09:15:00","Felt awful","Bench Press (Barbell)",,"",1,"normal",82.5,5,,,"#
        ]
        let csv = rows.joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        // Both rows group into one session (same title + start_time). The
        // second row's set is still imported; only its disagreeing
        // end_time AND description are dropped and counted — pinning
        // regression: the old accumulator silently ignored both.
        #expect(result.summary.setsImported == 2)
        #expect(result.summary.conflictingSessionMetadataDropped == 2)
        #expect(result.sessions.first?.notes == "Felt great")
    }

    @Test("finding 5.1 — a nonempty distance_km/duration_seconds must be finite and non-negative or the row is malformed")
    func invalidDistanceOrDurationIsMalformed() throws {
        func row(distance: String, duration: String) -> String {
            "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:45:00\",\"\",\"Running\",,\"\",1,\"normal\",,,\(distance),\(duration),"
        }

        let negativeDistance = ([Self.extendedHeader, row(distance: "-1", duration: "")]).joined(separator: "\n") + "\n"
        let nanDistance = ([Self.extendedHeader, row(distance: "NaN", duration: "")]).joined(separator: "\n") + "\n"
        let infiniteDistance = ([Self.extendedHeader, row(distance: "Infinity", duration: "")]).joined(separator: "\n") + "\n"
        let garbageDuration = ([Self.extendedHeader, row(distance: "", duration: "not-a-number")]).joined(separator: "\n") + "\n"

        let catalog = try loadCatalog()
        for csv in [negativeDistance, nanDistance, infiniteDistance, garbageDuration] {
            let result = try HevyCSVImporter.parse(csv: csv, catalog: catalog)
            // Pinning regression: these values previously fell through to
            // "0 => not cardio" (garbage/NaN/negative) or "positive value
            // => an ordinary cardio row" (Infinity) instead of being
            // reported as malformed.
            #expect(result.summary.malformedRowCount == 1)
            #expect(result.summary.cardioRowsSkipped == 0)
        }
    }

    @Test("finding 6.1 — a caller-provided timezone is used to interpret timezone-less timestamps instead of a silent UTC assumption")
    func explicitTimeZoneInterpretsWallClockTimestamps() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV(startTimeField: "2025-06-15 08:00:00")
        let catalog = try loadCatalog()
        let fourHoursBehindUTC = try #require(TimeZone(secondsFromGMT: -4 * 3600))

        let utcResult = try HevyCSVImporter.parse(csv: csv, catalog: catalog, timeZone: HevyTimestamp.defaultTimeZone)
        let shiftedResult = try HevyCSVImporter.parse(csv: csv, catalog: catalog, timeZone: fourHoursBehindUTC)

        let utcStart = try #require(utcResult.sessions.first?.startedAt)
        let shiftedStart = try #require(shiftedResult.sessions.first?.startedAt)

        // Pinning regression: the old parser always interpreted the
        // timezone-less "08:00:00" text as UTC regardless of any caller
        // input, so these two instants would previously always be equal.
        #expect(shiftedStart == utcStart.addingTimeInterval(4 * 3600))
    }

    @Test("finding 6.2 — end_time before start_time on the same row is malformed, not a negative-duration set")
    func endBeforeStartIsMalformed() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let row = "\"Push Day\",\"2025-06-15 10:00:00\",\"2025-06-15 09:00:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.malformedRows.first?.reason == .endBeforeStart)
    }

    @Test("finding 7.1 — NFC and NFD spellings of the same custom exercise name hash to the same identity across separate imports")
    func nfcAndNfdCustomExerciseNamesHashIdentically() throws {
        let catalog = try loadCatalog()
        let nfcTitle = "Caf\u{E9} Curl" // é precomposed (NFC)
        let nfdTitle = "Cafe\u{301} Curl" // e + combining acute (NFD) — canonically the same text

        let sessionNFC = FixtureSession(
            title: "Day A", start: start(), durationMinutes: 30,
            exercises: [FixtureExercise(title: nfcTitle, muscle: "Arms", sets: [FixtureSet(weightKg: 10, reps: 12)])]
        )
        let sessionNFD = FixtureSession(
            title: "Day A", start: start(), durationMinutes: 30,
            exercises: [FixtureExercise(title: nfdTitle, muscle: "Arms", sets: [FixtureSet(weightKg: 10, reps: 12)])]
        )

        // Two SEPARATE parse calls, simulating two separate imports (e.g.
        // a re-export on a different day) — the two names are `==` as
        // Swift `String`s (Swift's default equality is already canonical-
        // equivalence-based), so a bug here can only be seen by hashing
        // independently, not via an in-process dictionary lookup.
        let resultNFC = try HevyCSVImporter.parse(csv: HevyCSVGenerator.generate(sessions: [sessionNFC]), catalog: catalog)
        let resultNFD = try HevyCSVImporter.parse(csv: HevyCSVGenerator.generate(sessions: [sessionNFD]), catalog: catalog)

        // Pinning regression: hashing raw UTF-8 bytes (rather than an
        // NFC-normalized name) previously produced two different
        // persistent custom-exercise UUIDs across imports for a
        // canonically identical name.
        let idNFC = try #require(resultNFC.newExercises.first?.id)
        let idNFD = try #require(resultNFD.newExercises.first?.id)
        #expect(idNFC == idNFD)
    }

    @Test("finding 7.2 — case-fold-equivalent exercise names (German ß vs \"ss\") are treated as the same exercise for matching and dedup")
    func caseFoldEquivalentNamesDedupe() throws {
        let catalog = try loadCatalog()
        let sessionA = FixtureSession(
            title: "Day A", start: start(dayOffset: 0), durationMinutes: 30,
            exercises: [FixtureExercise(title: "Straße Press", muscle: "Chest", sets: [FixtureSet(weightKg: 40, reps: 8)])]
        )
        let sessionB = FixtureSession(
            title: "Day B", start: start(dayOffset: 2), durationMinutes: 30,
            exercises: [FixtureExercise(title: "STRASSE PRESS", muscle: "Chest", sets: [FixtureSet(weightKg: 42, reps: 8)])]
        )
        let csv = HevyCSVGenerator.generate(sessions: [sessionA, sessionB])
        let result = try HevyCSVImporter.parse(csv: csv, catalog: catalog)

        // Pinning regression: plain `.lowercased()` leaves "straße press"
        // and "strasse press" as two DIFFERENT strings (ß has no case to
        // lower), so the old importer created two separate custom
        // exercises instead of recognizing them as the same one.
        #expect(result.newExercises.count == 1)
        #expect(result.sessions[0].items[0].exerciseID == result.sessions[1].items[0].exerciseID)
    }

    // MARK: - m7-01 adversarial review round 2 — clean-redesign properties, at the importer level

    @Test("round-2 required property 2 — content glued onto a closing quote never silently becomes part of the value")
    func contentAfterClosingQuoteNeverCreatesACorruptedExercise() throws {
        // Pinning regression (round-2 new defect #1): `"Bench Press
        // (Barbell)"junk` used to tokenize as the single value
        // `Bench Press (Barbell)junk`, which would have created a
        // corrupted custom exercise instead of being rejected.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\"junk,1,\"normal\",80,5"
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 0)
        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.malformedRows.first?.reason == .contentAfterClosingQuote)
        #expect(result.newExercises.isEmpty)
    }

    @Test("round-2 finding — a real U+FFFD the file legitimately contained imports normally when the whole file decoded as strict UTF-8")
    func legitimateReplacementCharacterImportsNormallyWhenStrictDecodeSucceeded() throws {
        // Pinning regression: the old design flagged ANY U+FFFD as
        // `.invalidUTF8` regardless of whether the whole-file decode was
        // strict or lossy, so a perfectly valid UTF-8 file whose exercise
        // title genuinely contains U+FFFD was wrongly rejected.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Weird \u{FFFD} Press\",1,\"normal\",80,5"
        let csv = header + "\n" + row + "\n"
        // Fully valid UTF-8 bytes end-to-end (U+FFFD is a real, encodable
        // Unicode scalar) — strict decoding must succeed.
        let bytes = Data(csv.utf8)
        #expect(String(data: bytes, encoding: .utf8) != nil)

        let result = try HevyCSVImporter.parse(csvData: bytes, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.setsImported == 1)
        #expect(result.newExercises.first?.name == "Weird \u{FFFD} Press")
    }

    @Test("round-2 finding — the same real U+FFFD text is also legal via the String-based parse(csv:) overload")
    func legitimateReplacementCharacterImportsNormallyViaStringOverload() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Weird \u{FFFD} Press\",1,\"normal\",80,5"
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.setsImported == 1)
    }

    @Test("round-2 finding — a row flagged for genuinely undecodable bytes still gets full metadata-drop accounting, not a pre-decode early return")
    func undecodableRowStillAccountsForDroppedMetadata() throws {
        // Pinning regression: the old check ran BEFORE `decodeRow` at all,
        // so a row corrupted enough to need the lossy fallback contributed
        // to `malformedRowCount` but left every rpe/superset/notes/
        // set-type counter at zero even when those columns had values.
        let header = "title,start_time,end_time,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,rpe"
        var bytes = Data((header + "\n").utf8)
        var brokenRow = Data("\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bad".utf8)
        brokenRow.append(0xFF) // invalid standalone UTF-8 byte
        brokenRow.append(Data("Row\",\"grp-1\",\"tough one\",1,\"failure\",80,5,9\n".utf8))
        bytes.append(brokenRow)

        let result = try HevyCSVImporter.parse(csvData: bytes, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.malformedRows.first?.reason == .invalidUTF8)
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.rpeValuesDropped == 1)
        #expect(result.summary.supersetRowsDropped == 1)
        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 1)
    }

    @Test("round-2 finding — a wrong-column-count row still gets a best-effort metadata-drop count, not an unconditional zero")
    func wrongColumnCountRowStillAccountsForDroppedMetadata() throws {
        // Pinning regression: the old `decodeRow` returned
        // `RowMetadataDrops()` unconditionally for a wrong-column-count
        // row, discarding any rpe/superset/notes/set-type value that
        // happened to still be in range.
        let header = "title,start_time,end_time,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,rpe"
        // One fewer field than the header declares.
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",\"grp-1\",\"tough one\",1,\"failure\",80,5"
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 1)
        #expect(result.summary.malformedRows.first?.reason == .wrongColumnCount(expected: 11, actual: 10))
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.supersetRowsDropped == 1)
        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 1)
    }

    @Test("round-2 finding — duplicate unknown columns each count their own dropped value, not collapsed to one")
    func duplicateUnknownColumnsEachCountIndependently() throws {
        // Pinning regression: the header map deduplicated by column NAME,
        // so a header with `tempo` twice only ever reported one dropped
        // value even when both occurrences had a nonempty value in a row.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps,tempo,tempo"
        let row = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5,\"3-1-1\",\"slow\""
        let csv = header + "\n" + row + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.unknownColumnValuesDropped == 2)
    }

    // MARK: - m7-01 adversarial review round 3

    @Test("round-3 adjudication 1 — an unterminated quote's consumed remainder is surfaced honestly on the summary, not just buried in the malformed-row list")
    func rowsLostToUnterminatedQuoteIsSurfacedOnSummary() throws {
        // Pinning regression / FIX 1 "surface the count honestly": once a
        // bound trips inside an open quote, everything from that point to
        // true EOF is discarded as one malformed record (round-3
        // adjudication — see CSVTokenizer's FAILURE-MODE TABLE). The
        // whole-file total of how many rows that cost must be visible
        // directly on the summary, not something a caller has to
        // reconstruct by filtering `malformedRows` for this one reason
        // and summing its payloads. (A plain unterminated quote with no
        // bound ever tripped reaches true EOF with nothing further to
        // lose — see the CSVTokenizer test pinning `approxRowsLost == 0`
        // for that case — so this test deliberately trips the field-size
        // bound to exercise a nonzero count.)
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let goodRow = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        // The bound trips partway through this row's first (quoted)
        // field; everything after — the rest of this row, plus the two
        // "good-looking" rows that follow — is discarded as one record.
        let brokenRow = "\"\(hugeField)\",b,c,d,e,f,g"
        let swallowedA = "whatever,row,four"
        let swallowedB = "whatever,row,five"
        let csv = [header, goodRow, brokenRow, swallowedA, swallowedB].joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.setsImported == 1)
        #expect(result.summary.malformedRowCount == 1)
        guard case .unterminatedQuoteConsumedRemainder(let approxRowsLost) = result.summary.malformedRows.first?.reason else {
            Issue.record("expected .unterminatedQuoteConsumedRemainder, got \(String(describing: result.summary.malformedRows.first?.reason))")
            return
        }
        // Three terminators are skipped after the bound trips: the end of
        // the broken row itself, and the ends of the two swallowed rows.
        #expect(approxRowsLost == 3)
        #expect(result.summary.rowsLostToUnterminatedQuote == 3)
    }

    @Test("round-3 finding 3.1 — tokenizer-level malformed rows never fake per-category drop counts from unparseable data")
    func tokenizerLevelFailuresNeverFakeDropCounts() throws {
        // Contract pin (FIX 3): a row the tokenizer itself couldn't safely
        // turn into fields at all (blank, oversized, stray quote,
        // content-after-closing-quote, unterminated quote) must NEVER be
        // reflected in the per-category dropped-value counters — there is
        // no safe way to scan for an rpe/superset_id/etc. value inside
        // data that was never reliably tokenized. Every category should
        // read exactly zero here even though every row is malformed.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let blank = ""
        let strayQuote = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",Bad\"Title,1,\"normal\",80,5"
        let contentAfterClose = "\"Push Day\"junk,\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Bench Press (Barbell)\",1,\"normal\",80,5"
        let csv = [header, blank, strayQuote, contentAfterClose].joined(separator: "\n") + "\n"

        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())

        #expect(result.summary.malformedRowCount == 3)
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.rpeValuesDropped == 0)
        #expect(result.summary.supersetRowsDropped == 0)
        #expect(result.summary.exerciseNotesDropped == 0)
        #expect(result.summary.setIndexValuesDropped == 0)
        #expect(result.summary.unknownColumnValuesDropped == 0)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 0)
    }

    @Test("round-3 finding 4.1 — a genuinely invalid byte elsewhere in the file conservatively quarantines an otherwise-clean row containing a real U+FFFD too, and the summary says so")
    func coexistingInvalidByteAndLegitimateReplacementCharacterAreBothQuarantinedAndFlagged() throws {
        // Adjudicated outcome: keep the conservative quarantine (never
        // invent data), but surface that it happened. Byte-range
        // precision (flagging only the row whose bytes actually failed)
        // is deferred to m7-03.
        let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"
        let cleanRowWithRealFFFD = "\"Push Day\",\"2025-06-15 08:00:00\",\"2025-06-15 08:30:00\",\"Weird \u{FFFD} Press\",1,\"normal\",80,5"
        var bytes = Data((header + "\n" + cleanRowWithRealFFFD + "\n").utf8)
        var brokenRow = Data("\"Push Day\",\"2025-06-15 09:00:00\",\"2025-06-15 09:30:00\",\"Bad".utf8)
        brokenRow.append(0xFF) // invalid standalone UTF-8 byte
        brokenRow.append(Data("Row\",2,\"normal\",80,5\n".utf8))
        bytes.append(brokenRow)

        let result = try HevyCSVImporter.parse(csvData: bytes, catalog: try loadCatalog())

        // Conservative quarantine: the whole file needed the lossy
        // fallback, so EVERY row containing U+FFFD is flagged, including
        // the row whose U+FFFD was always genuine content.
        #expect(result.summary.malformedRowCount == 2)
        #expect(result.summary.malformedRows.allSatisfy { $0.reason == .invalidUTF8 })
        #expect(result.summary.setsImported == 0)
        #expect(result.summary.encodingDamageDetected == true)
    }

    @Test("round-3 finding 4.1 — a file with no invalid bytes at all reports encodingDamageDetected false")
    func cleanFileReportsNoEncodingDamage() throws {
        let csv = HevyCSVGeneratorTestSupport.singleRowCSV()
        let result = try HevyCSVImporter.parse(csv: csv, catalog: try loadCatalog())
        #expect(result.summary.encodingDamageDetected == false)
        #expect(result.summary.rowsLostToUnterminatedQuote == 0)
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
