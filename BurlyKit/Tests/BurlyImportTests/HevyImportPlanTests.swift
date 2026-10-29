// SPDX-License-Identifier: GPL-3.0-or-later
//
// Task m7-02: the import plan behind the phone's preview/commit screen.
// Spec §8 acceptance #2 (same file twice -> zero duplicates; overlapping
// newer export -> only new sessions), #3 (imports never link or write an
// HKWorkout), and #4 (preview numbers match the final import result
// exactly), plus the binding m7-01 carry-over that the dropped-data report
// reaches the preview whole.
//
// Every CSV here is synthetic, hand-written text against the extended Hevy
// column set `HevyCSVImporterTests` already uses.
import BurlyCore
import BurlyPersistence
import Foundation
import Testing
@testable import BurlyImport

@Suite("HevyImportPlan — spec §8 preview/commit (m7-02)")
@MainActor
struct HevyImportPlanTests {
    private static let header = "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe"

    /// Three workouts: two alias-matched catalog exercises, one name no
    /// catalog entry or alias knows (becomes a custom), and a 4-row session.
    private static let threeWorkouts = [
        header,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"warmup",40,10,,,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",1,"normal",80,5,,,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Zorblax Press",,"",2,"normal",20,12,,,"#,
        #""Leg Day","2025-06-17 18:00:00","2025-06-17 19:00:00","","Squat (Barbell)",,"",0,"normal",100,5,,,"#,
        #""Leg Day","2025-06-17 18:00:00","2025-06-17 19:00:00","","Squat (Barbell)",,"",1,"normal",100,5,,,"#,
        #""Push Day","2025-06-19 08:00:00","2025-06-19 08:50:00","","Zorblax Press",,"",0,"normal",22,10,,,"#
    ].joined(separator: "\n") + "\n"

    /// A newer export overlapping `threeWorkouts`: repeats the last two
    /// workouts and adds one more.
    private static let overlappingNewer = [
        header,
        #""Leg Day","2025-06-17 18:00:00","2025-06-17 19:00:00","","Squat (Barbell)",,"",0,"normal",100,5,,,"#,
        #""Leg Day","2025-06-17 18:00:00","2025-06-17 19:00:00","","Squat (Barbell)",,"",1,"normal",100,5,,,"#,
        #""Push Day","2025-06-19 08:00:00","2025-06-19 08:50:00","","Zorblax Press",,"",0,"normal",22,10,,,"#,
        #""Pull Day","2025-06-21 09:00:00","2025-06-21 09:40:00","","Zorblax Press",,"",0,"normal",24,8,,,"#,
        #""Pull Day","2025-06-21 09:00:00","2025-06-21 09:40:00","","Gloopfinger Curl",,"",1,"normal",12,12,,,"#
    ].joined(separator: "\n") + "\n"

    /// Every dropped-data category nonzero at once.
    private static let everyDropCategory = [
        header,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)","grp-1","felt good",0,"failure",80,5,,,8.5"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Running",,"",1,"normal",,,5.0,1800,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",2,"normal",80,"lots",,,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",3,"dropset",60,8,,,"#
    ].joined(separator: "\n") + "\n"

    private func catalog() throws -> CatalogSeed {
        try CatalogSeed.loadBundled()
    }

    private func parse(_ csv: String) throws -> HevyImportResult {
        try HevyCSVImporter.parse(csv: csv, catalog: try catalog())
    }

    private func allCatalogIDs() throws -> Set<UUID> {
        Set(try catalog().exercises.map(\.id))
    }

    /// Records writes and can be told to throw on the Nth session write.
    private final class RecordingWriter {
        var exercises: [ExerciseData] = []
        var sessions: [SessionData] = []
        var failOnSessionWrite: Int?

        struct InjectedFailure: Error {}

        func createExercise(_ exercise: ExerciseData) throws {
            exercises.append(exercise)
        }

        func createSession(_ session: SessionData) throws {
            if let failOnSessionWrite, sessions.count == failOnSessionWrite {
                throw InjectedFailure()
            }
            sessions.append(session)
        }
    }

    private func apply(_ plan: HevyImportPlan, to writer: RecordingWriter) -> HevyImportOutcome {
        plan.apply(createExercise: writer.createExercise, createSession: writer.createSession)
    }

    // MARK: - Preview numbers (fresh store)

    @Test("against a store with the catalog, the preview counts every workout, set and new custom")
    func freshPreviewCountsEverything() throws {
        let result = try parse(Self.threeWorkouts)
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.preview.workoutsInFile == 3)
        #expect(plan.preview.newWorkoutCount == 3)
        #expect(plan.preview.alreadyImportedWorkoutCount == 0)
        #expect(plan.preview.setCount == 6)
        #expect(plan.preview.exercisesMatched == 2)
        #expect(plan.preview.newCustomExerciseNames == ["Zorblax Press"])
        #expect(plan.exercisesToCreate.map(\.origin) == [.hevyImport])

        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let range = try #require(plan.preview.fileDateRange)
        #expect(utc.dateComponents([.year, .month, .day], from: range.lowerBound) == DateComponents(year: 2025, month: 6, day: 15))
        #expect(utc.dateComponents([.year, .month, .day], from: range.upperBound) == DateComponents(year: 2025, month: 6, day: 19))
        #expect(plan.preview.newWorkoutDateRange == range)
    }

    @Test("catalog matches the store lacks are restored as curated rows, not counted as new customs")
    func missingCatalogRowsAreRestoredNotCountedAsCustom() throws {
        let plan = try HevyImportPlan.make(
            result: try parse(Self.threeWorkouts), catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: []
        )

        #expect(plan.preview.exercisesMatched == 2)
        #expect(plan.preview.newCustomExerciseCount == 1)
        #expect(plan.exercisesToCreate.filter { $0.origin == .curated }.count == 2)
        // Exercises are written before anything references them.
        #expect(plan.exercisesToCreate.count == 3)
    }

    // MARK: - Acceptance #2: re-import upserts

    @Test("the same file planned again after its import writes nothing")
    func sameFileTwiceAddsNothing() throws {
        let result = try parse(Self.threeWorkouts)
        let writer = RecordingWriter()
        let first = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )
        _ = apply(first, to: writer)

        let again = try HevyImportPlan.make(
            result: try parse(Self.threeWorkouts), catalog: try catalog(),
            existingSessionIDs: Set(writer.sessions.map(\.id)),
            existingExerciseIDs: try allCatalogIDs().union(writer.exercises.map(\.id))
        )

        #expect(again.preview.isNothingNew)
        #expect(again.preview.alreadyImportedWorkoutCount == 3)
        #expect(again.preview.setCount == 0)
        #expect(again.preview.newCustomExerciseCount == 0)
        #expect(again.exercisesToCreate.isEmpty)
        #expect(again.sessionsToCreate.isEmpty)
        // The file's dates still show, so the time-zone line stays checkable.
        #expect(again.preview.fileDateRange != nil)
        #expect(again.preview.newWorkoutDateRange == nil)
    }

    @Test("an overlapping newer export adds only the workouts and customs not yet stored")
    func overlappingExportAddsOnlyNew() throws {
        let writer = RecordingWriter()
        _ = apply(try HevyImportPlan.make(
            result: try parse(Self.threeWorkouts), catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        ), to: writer)

        let newer = try HevyImportPlan.make(
            result: try parse(Self.overlappingNewer), catalog: try catalog(),
            existingSessionIDs: Set(writer.sessions.map(\.id)),
            existingExerciseIDs: try allCatalogIDs().union(writer.exercises.map(\.id))
        )

        #expect(newer.preview.workoutsInFile == 3)
        #expect(newer.preview.newWorkoutCount == 1)
        #expect(newer.preview.alreadyImportedWorkoutCount == 2)
        #expect(newer.preview.setCount == 2)
        // "Zorblax Press" already exists from the first import: matched now.
        #expect(newer.preview.exercisesMatched == 1)
        #expect(newer.preview.newCustomExerciseNames == ["Gloopfinger Curl"])
        #expect(newer.sessionsToCreate.count == 1)
        #expect(Set(newer.sessionsToCreate.map(\.id)).isDisjoint(with: writer.sessions.map(\.id)))
    }

    // MARK: - Acceptance #4: preview == result

    @Test("apply writes exactly the planned rows and its outcome equals the preview")
    func previewMatchesOutcome() throws {
        let plan = try HevyImportPlan.make(
            result: try parse(Self.threeWorkouts), catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: []
        )
        let writer = RecordingWriter()
        let outcome = apply(plan, to: writer)

        #expect(outcome.matches(plan.preview))
        #expect(outcome.sessionsCreated == plan.preview.newWorkoutCount)
        #expect(outcome.setsCreated == plan.preview.setCount)
        #expect(outcome.customExercisesCreated == plan.preview.newCustomExerciseCount)
        #expect(outcome.catalogExercisesRestored == 2)
        #expect(writer.exercises == plan.exercisesToCreate)
        #expect(writer.sessions == plan.sessionsToCreate)
    }

    @Test("stepping the cursor writes the same rows, in the same order, as apply")
    func cursorMatchesApply() throws {
        let plan = try HevyImportPlan.make(
            result: try parse(Self.threeWorkouts), catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: []
        )
        let stepped = RecordingWriter()
        var cursor = HevyImportCommitCursor(plan: plan)
        #expect(cursor.totalWrites == 6)
        var progress: [Int] = []
        while cursor.isFinished == false {
            cursor.writeNext(createExercise: stepped.createExercise, createSession: stepped.createSession)
            progress.append(cursor.completedWrites)
        }
        // Finished cursors ignore further steps.
        cursor.writeNext(createExercise: stepped.createExercise, createSession: stepped.createSession)

        let oneShot = RecordingWriter()
        let outcome = apply(plan, to: oneShot)
        #expect(progress == [1, 2, 3, 4, 5, 6])
        #expect(cursor.outcome == outcome)
        #expect(stepped.exercises == oneShot.exercises)
        #expect(stepped.sessions == oneShot.sessions)
    }

    @Test("a write failing part-way reports what landed, and re-planning writes only the rest")
    func partialFailureIsReportedAndRetryIsIdempotent() throws {
        let result = try parse(Self.threeWorkouts)
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )
        let writer = RecordingWriter()
        writer.failOnSessionWrite = 1
        let outcome = apply(plan, to: writer)

        #expect(outcome.isComplete == false)
        #expect(outcome.matches(plan.preview) == false)
        #expect(outcome.sessionsCreated == 1)
        #expect(outcome.failure?.stage == .session)
        #expect(outcome.failure?.id == plan.sessionsToCreate[1].id)

        let retry = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: Set(writer.sessions.map(\.id)),
            existingExerciseIDs: try allCatalogIDs().union(writer.exercises.map(\.id))
        )
        #expect(retry.preview.newWorkoutCount == 2)
        #expect(retry.preview.alreadyImportedWorkoutCount == 1)
        writer.failOnSessionWrite = nil
        let retryOutcome = apply(retry, to: writer)
        #expect(retryOutcome.matches(retry.preview))
        #expect(Set(writer.sessions.map(\.id)) == Set(plan.sessionsToCreate.map(\.id)))
    }

    // MARK: - Acceptance #3: no HealthKit link

    @Test("planned sessions never carry a HealthKit workout ID, even if the input did")
    func plannedSessionsNeverLinkHealthKit() throws {
        let parsed = try parse(Self.threeWorkouts)
        // Forge an input that claims a Health workout, to prove the plan
        // enforces the rule rather than inheriting the importer's nil.
        let forged = HevyImportResult(
            sessions: parsed.sessions.map { session in
                var linked = session
                linked.healthKitWorkoutID = UUID()
                return linked
            },
            newExercises: parsed.newExercises,
            summary: parsed.summary
        )
        let plan = try HevyImportPlan.make(
            result: forged, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.sessionsToCreate.isEmpty == false)
        #expect(plan.sessionsToCreate.allSatisfy { $0.healthKitWorkoutID == nil })
        #expect(plan.sessionsToCreate.allSatisfy { $0.origin == .hevyImport && $0.state == .logged })
    }

    // MARK: - Drop report passthrough (m7-01 carry-over)

    @Test("the plan carries the parse's whole dropped-data report unchanged")
    func dropReportPassesThrough() throws {
        let result = try parse(Self.everyDropCategory)
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.fileSummary == result.summary)
        #expect(plan.fileSummary.cardioRowsSkipped == 1)
        #expect(plan.fileSummary.rpeValuesDropped == 1)
        #expect(plan.fileSummary.supersetRowsDropped == 1)
        #expect(plan.fileSummary.nonStandardSetTypeMarkersFlattened == 2)
        #expect(plan.fileSummary.malformedRowCount == 1)
        #expect(plan.preview.setCount == 2)
    }

    @Test("a re-import still reports the file's drops")
    func dropReportSurvivesReimport() throws {
        let result = try parse(Self.everyDropCategory)
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: Set(result.sessions.map(\.id)), existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.preview.isNothingNew)
        #expect(plan.fileSummary == result.summary)
    }

    @Test("encoding damage and rows lost to an unterminated quote reach the plan")
    func encodingDamageAndUnterminatedQuoteReachThePlan() throws {
        var bytes = Data((Self.header + "\n").utf8)
        bytes.append(Data(#""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"normal",80,5,,,"#.utf8))
        bytes.append(Data("\n".utf8))
        // One invalid UTF-8 byte inside an otherwise ordinary row.
        bytes.append(Data(#""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench "#.utf8))
        bytes.append(0xFF)
        bytes.append(Data(#"",,"",1,"normal",80,5,,,"#.utf8))
        bytes.append(Data("\n".utf8))
        // An opening quote that never closes, swallowing the (quote-free)
        // rows after it to the end of the file.
        bytes.append(Data(#""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell),,,2,normal,80,5,,,"#.utf8))
        bytes.append(Data("\n".utf8))
        bytes.append(Data("Push Day,2025-06-15 08:00:00,2025-06-15 08:45:00,,Bench Press (Barbell),,,3,normal,80,5,,,\n".utf8))
        bytes.append(Data("Push Day,2025-06-15 08:00:00,2025-06-15 08:45:00,,Bench Press (Barbell),,,4,normal,80,5,,,\n".utf8))

        let result = try HevyCSVImporter.parse(csvData: bytes, catalog: try catalog())
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.fileSummary.encodingDamageDetected)
        #expect(plan.fileSummary.malformedRows.contains { $0.reason == .invalidUTF8 })
        #expect(plan.fileSummary.malformedRows.contains {
            if case .unterminatedQuoteConsumedRemainder = $0.reason { return true }
            return false
        })
        // (A quote left open to end-of-file is discovered AT end-of-file, so
        // the tokenizer reports its approximate loss as 0 — m7-01's
        // contract; a nonzero total needs a size bound tripping mid-file.
        // Either way the plan carries the parse's number unchanged.)
        #expect(plan.fileSummary.rowsLostToUnterminatedQuote == result.summary.rowsLostToUnterminatedQuote)
        #expect(plan.fileSummary == result.summary)
        // The clean first row still imports.
        #expect(plan.preview.setCount == 1)
    }

    // MARK: - The app's UI-test fixture

    /// BurlyPhoneUITests/ImportUITests asserts literal preview numbers for
    /// the app's bundled synthetic export; the UI test target cannot import
    /// anything, so this pins those same numbers against the parser and
    /// planner, where a drift fails fast instead of in a simulator run.
    @Test("the phone app's synthetic UI-test export parses to the numbers ImportUITests asserts")
    func appUITestFixtureParsesToTheNumbersTheUITestAsserts() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurlyImportTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BurlyKit
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("BurlyPhone/Preview Content/HevySyntheticFixture.csv")
        let result = try HevyCSVImporter.parse(
            csvData: try Data(contentsOf: fixtureURL),
            catalog: try catalog(),
            timeZone: .current
        )
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: try allCatalogIDs()
        )

        #expect(plan.preview.newWorkoutCount == 3)
        #expect(plan.preview.alreadyImportedWorkoutCount == 0)
        #expect(plan.preview.setCount == 7)
        #expect(plan.preview.exercisesMatched == 3)
        #expect(plan.preview.newCustomExerciseNames == ["Fixture Zorblax Press"])
        #expect(plan.fileSummary.cardioRowsSkipped == 1)
        #expect(plan.fileSummary.rpeValuesDropped == 1)
        #expect(plan.fileSummary.supersetRowsDropped == 2)
        #expect(plan.fileSummary.nonStandardSetTypeMarkersFlattened == 1)
        #expect(plan.fileSummary.encodingDamageDetected == false)
        #expect(plan.fileSummary.rowsLostToUnterminatedQuote == 0)
        #expect(plan.fileSummary.malformedRows.map(\.rowNumber) == [10])
        #expect(plan.fileSummary.malformedRows.first?.reason == .invalidReps("eight"))

        let again = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: Set(result.sessions.map(\.id)),
            existingExerciseIDs: try allCatalogIDs().union(plan.exercisesToCreate.map(\.id))
        )
        #expect(again.preview.newWorkoutCount == 0)
        #expect(again.preview.alreadyImportedWorkoutCount == 3)
    }

    // MARK: - Against the real store

    @Test("against a real phone store: import, re-import, overlap — no duplicateID, preview == stored rows")
    func realStoreRoundTrip() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        _ = try SeedLoader.applyBundled(to: store)

        func plan(_ csv: String) throws -> HevyImportPlan {
            let result = try parse(csv)
            let existingSessions = Set(try result.sessions.compactMap { try store.session(id: $0.id)?.id })
            let existingExercises = Set(try store.exercises(includingArchived: true).map(\.id))
            return try HevyImportPlan.make(
                result: result, catalog: try catalog(),
                existingSessionIDs: existingSessions, existingExerciseIDs: existingExercises
            )
        }
        func commit(_ plan: HevyImportPlan) -> HevyImportOutcome {
            plan.apply(createExercise: { try store.createExercise($0) }, createSession: { try store.createSession($0) })
        }

        let first = try plan(Self.threeWorkouts)
        let firstOutcome = commit(first)
        #expect(firstOutcome.matches(first.preview))
        #expect(try store.sessions().count == 3)
        #expect(try store.sessions().allSatisfy { $0.healthKitWorkoutID == nil && $0.origin == .hevyImport })

        let again = try plan(Self.threeWorkouts)
        #expect(again.preview.isNothingNew)
        #expect(commit(again).matches(again.preview))
        #expect(try store.sessions().count == 3)

        let newer = try plan(Self.overlappingNewer)
        #expect(newer.preview.newWorkoutCount == 1)
        #expect(commit(newer).matches(newer.preview))
        #expect(try store.sessions().count == 4)
        #expect(try store.exercises(includingArchived: true).filter { $0.origin == .hevyImport }.count == 2)
    }

    @Test("an archived custom from an earlier import counts as matched and is not re-created")
    func archivedExerciseStillCountsAsExisting() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        _ = try SeedLoader.applyBundled(to: store)
        let firstResult = try parse(Self.threeWorkouts)
        let first = try HevyImportPlan.make(
            result: firstResult, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: Set(try store.exercises(includingArchived: true).map(\.id))
        )
        _ = first.apply(createExercise: { try store.createExercise($0) }, createSession: { try store.createSession($0) })
        let custom = try #require(firstResult.newExercises.first)
        try store.archiveExercise(id: custom.id, at: Date(timeIntervalSince1970: 1_780_000_000))

        let newerResult = try parse(Self.overlappingNewer)
        let newer = try HevyImportPlan.make(
            result: newerResult, catalog: try catalog(),
            existingSessionIDs: Set(try newerResult.sessions.compactMap { try store.session(id: $0.id)?.id }),
            existingExerciseIDs: Set(try store.exercises(includingArchived: true).map(\.id))
        )
        #expect(newer.exercisesToCreate.contains { $0.id == custom.id } == false)
        #expect(newer.apply(createExercise: { try store.createExercise($0) }, createSession: { try store.createSession($0) }).matches(newer.preview))
    }

    @Test("a store the catalog seed never reached still imports catalog-matched workouts")
    func unseededStoreImports() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let result = try parse(Self.threeWorkouts)
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: []
        )
        let outcome = plan.apply(createExercise: { try store.createExercise($0) }, createSession: { try store.createSession($0) })

        #expect(outcome.matches(plan.preview))
        #expect(try store.sessions().count == 3)
        // A later seed application skips the restored rows by UUID.
        _ = try SeedLoader.applyBundled(to: store)
        #expect(try store.exercises(includingArchived: true).filter { $0.origin == .curated }.count == (try catalog().exercises.count))
    }
}
