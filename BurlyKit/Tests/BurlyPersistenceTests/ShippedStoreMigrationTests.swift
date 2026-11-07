// SPDX-License-Identifier: GPL-3.0-or-later
// A store TestFlight 0.9.1 wrote opens in this build with everything in it.
//
// ## The fixtures
//
// Fixtures/ShippedV1/Burly-phone.store and Burly-watch.store were written on
// 2026-11-03 by the BurlyKit sources at burly-rc1 (37ea85e, the 0.9.1
// build), through that tree's own `SwiftDataStore` and its stage-free
// `[BurlySchemaV1]` plan, then committed untouched (the write-ahead log
// was already empty, so the .store file is the whole store). They are the
// shape a tester's devices hold today. Regenerating them from any later
// commit would test nothing: the point is that they come from the shipped
// code, not from this tree's idea of V1.
//
// The ids below are the ones that generator used; everything else in the
// assertions is the content it wrote (bundled catalog, two routines, three
// phone sessions of each origin with sets, a naming placeholder; on the
// watch an unacked finished session, an in-flight one with its journal, a
// digest and the watch-sync journal).
//
// ## Why this runs in the ungated pass
//
// Opening a V1 file realises V1 and V2 in one process, under the same
// entity names. That is exactly what a device does on its first 1.0 launch,
// and V2 changes no entity V1 has (MigrationPlanTests.v2CopiesV1Verbatim),
// so it is not the hazard MigrationSpikeTests isolates. Every test here
// opens the file through `BurlyContainer`, the production path; none builds
// a V1 container of its own.

import CoreData
import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

enum ShippedV1Fixture {
    static let bench = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    static let custom = UUID(uuidString: "F1000000-0000-4000-8000-000000000001")!
    static let hevyCustom = UUID(uuidString: "F1000000-0000-4000-8000-000000000002")!
    static let placeholder = UUID(uuidString: "F1000000-0000-4000-8000-000000000003")!
    static let pushRoutine = UUID(uuidString: "F2000000-0000-4000-8000-000000000001")!
    static let legsRoutine = UUID(uuidString: "F2000000-0000-4000-8000-000000000002")!
    static let watchSession = UUID(uuidString: "F3000000-0000-4000-8000-000000000001")!
    static let editedSession = UUID(uuidString: "F3000000-0000-4000-8000-000000000002")!
    static let hevySession = UUID(uuidString: "F3000000-0000-4000-8000-000000000003")!
    static let watchWorkout = UUID(uuidString: "F4000000-0000-4000-8000-000000000001")!
    static let editedWorkout = UUID(uuidString: "F4000000-0000-4000-8000-000000000002")!
    static let watchFinished = UUID(uuidString: "F3000000-0000-4000-8000-000000000011")!
    static let watchActive = UUID(uuidString: "F3000000-0000-4000-8000-000000000012")!

    /// Copies the named fixture to a fresh temporary location, because
    /// opening it migrates it in place and the bundled copy must stay V1.
    static func copy(_ kind: BurlyStoreKind) throws -> URL {
        let source = try #require(
            Bundle.module.url(
                forResource: kind.storeName,
                withExtension: "store",
                subdirectory: "ShippedV1"
            )
        )
        let destination = try makeTemporaryStoreURL()
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// The entity names the file's own metadata says it was written with.
    /// Read straight from the SQLite metadata, without opening a container,
    /// so it reports what is on disk rather than what a schema assumes.
    static func storedEntityNames(at url: URL) throws -> Set<String> {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: url
        )
        let hashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Any])
        return Set(hashes.keys)
    }
}

@MainActor
@Suite("TestFlight 0.9.1 stores open through V1 → V2 with their data intact")
struct ShippedStoreMigrationTests {
    typealias IDs = ShippedV1Fixture

    @Test("the fixtures really are V1: ten entities, no tombstone table")
    func fixturesAreV1() throws {
        for kind in BurlyStoreKind.allCases {
            let url = try ShippedV1Fixture.copy(kind)
            defer { removeStoreFiles(at: url) }
            let names = try ShippedV1Fixture.storedEntityNames(at: url)
            #expect(names == Set(MigrationPlanTests.shippedV1ModelNames), "\(kind)")
        }
    }

    @Test("a 0.9.1 phone store opens with every routine, session and set, then deletes with a tombstone that holds")
    func phoneStoreMigratesAndDeletesWithTombstone() throws {
        let url = try ShippedV1Fixture.copy(.phone)
        defer { removeStoreFiles(at: url) }
        let clock = TestClock(Fixture.epoch.addingTimeInterval(30 * 86_400))

        // What the watch would send again, and the placeholder riding with
        // it, kept for the re-deliveries below.
        let (redelivery, placeholder) = try autoreleasepool { () throws -> (SessionData, ExerciseData) in
            let container = try BurlyContainer.phone(at: .file(url))
            let store = SwiftDataStore(container: container, clock: clock)
            let raw = ModelContext(container)

            // The open migrated the file: its metadata now names V2's
            // eleven entities, and the new table is there and empty.
            #expect(
                try ShippedV1Fixture.storedEntityNames(at: url)
                    == Set(MigrationPlanTests.shippedV1ModelNames + ["SessionTombstone"])
            )
            #expect(try raw.fetchCount(FetchDescriptor<SessionTombstone>()) == 0)

            // Catalog, customs and the naming placeholder: 103 bundled
            // exercises plus the three the fixture added.
            let exercises = try store.exercises(includingArchived: true)
            #expect(exercises.count == 106)
            #expect(try raw.fetchCount(FetchDescriptor<CatalogSeedState>()) == 1)
            #expect(try store.exercise(id: IDs.custom) == ExerciseData(
                id: IDs.custom, name: "Landmine Press", muscleGroups: [.shoulders, .chest], origin: .custom
            ))
            #expect(try store.exercise(id: IDs.hevyCustom)?.origin == .hevyImport)
            let placeholder = try #require(try store.exercise(id: IDs.placeholder))
            #expect(placeholder.needsNaming)
            #expect(placeholder.name == "Watch Workout")

            // Routines, the archived one included, with their items.
            let routines = try store.routines(includingArchived: true)
            #expect(routines.count == 2)
            let push = try #require(try store.routine(id: IDs.pushRoutine))
            #expect(push.name == "Push A")
            #expect(push.archivedAt == nil)
            #expect(push.items.map(\.exerciseID) == [IDs.bench, IDs.custom])
            #expect(push.items[0].restOverride == 120)
            #expect(push.items[0].note == "top set first")
            let legs = try #require(try store.routine(id: IDs.legsRoutine))
            #expect(legs.archivedAt != nil)
            #expect(legs.items.count == 1)
            #expect(legs.items[0].defaultSetCount == 5)
            #expect(try store.routines(includingArchived: false).map(\.id) == [IDs.pushRoutine])

            // Sessions of every kind, with their sets in order.
            #expect(try store.loggedSessionCount() == 3)
            let watch = try #require(try store.session(id: IDs.watchSession))
            #expect(watch.origin == .live)
            #expect(watch.revision == 1)
            #expect(watch.healthKitWorkoutID == IDs.watchWorkout)
            #expect(watch.routineID == IDs.pushRoutine)
            #expect(watch.items.map(\.exerciseID) == [IDs.bench, IDs.placeholder])
            #expect(watch.items[0].sets.map(\.weightKg) == [60, 100, 102.5])
            #expect(watch.items[0].sets.map(\.reps) == [8, 5, 5])
            #expect(watch.items[0].sets.map(\.isWarmup) == [true, false, false])
            #expect(watch.items[1].sets.map(\.reps) == [12])

            let edited = try #require(try store.session(id: IDs.editedSession))
            #expect(edited.revision == 2)
            #expect(edited.notes == "Knee felt fine")
            #expect(edited.healthKitWorkoutID == IDs.editedWorkout)
            #expect(edited.items.first?.exerciseID == legs.items[0].exerciseID)
            #expect(edited.items.first?.sets.map(\.reps) == [5, 4])
            #expect(edited.items.first?.sets.map(\.weightKg) == [140, 140])

            let hevy = try #require(try store.session(id: IDs.hevySession))
            #expect(hevy.origin == .hevyImport)
            #expect(hevy.healthKitWorkoutID == nil)
            #expect(hevy.routineName == "Old Hevy Day")
            #expect(hevy.items.map(\.exerciseID) == [IDs.hevyCustom, IDs.bench])
            #expect(hevy.items.map { $0.sets.count } == [2, 1])

            // The stats reads see the migrated history too.
            #expect(try store.allLoggedSessionDates().count == 3)

            // Now the reason V2 exists, on the migrated file: the delete
            // takes the session and its sets, returns the Health link, and
            // a watch re-delivery of the same session is settled, not new.
            let redelivery = watch
            #expect(try store.deleteLoggedSession(id: IDs.watchSession) == IDs.watchWorkout)
            #expect(try store.session(id: IDs.watchSession) == nil)
            #expect(try store.loggedSessionCount() == 2)
            #expect(try raw.fetchCount(FetchDescriptor<SessionTombstone>()) == 1)
            #expect(
                try store.applyReplicatedSession(redelivery, upsertingPlaceholderExercises: [placeholder])
                    == redelivery.revision
            )
            #expect(try store.session(id: IDs.watchSession) == nil)
            return (redelivery, placeholder)
        }

        // Cold reopen of the now-V2 file: no stage left to run, the delete
        // and its tombstone are durable, and the rest of history is intact.
        try autoreleasepool {
            let container = try BurlyContainer.phone(at: .file(url))
            let store = SwiftDataStore(container: container, clock: clock)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<SessionTombstone>()) == 1)
            #expect(try store.session(id: IDs.watchSession) == nil)
            #expect(try store.sessionExists(id: IDs.editedSession))
            #expect(try store.sessionExists(id: IDs.hevySession))
            #expect(try store.routines(includingArchived: true).count == 2)
            #expect(
                try store.applyReplicatedSession(redelivery, upsertingPlaceholderExercises: [placeholder])
                    == redelivery.revision
            )
            #expect(try store.loggedSessionCount() == 2)
        }
    }

    @Test("a 0.9.1 watch store opens with its unacked session, its in-flight session and its journals")
    func watchStoreMigrates() throws {
        let url = try ShippedV1Fixture.copy(.watch)
        defer { removeStoreFiles(at: url) }

        try autoreleasepool {
            let container = try BurlyContainer.watch(at: .file(url))
            let store = SwiftDataStore(container: container, clock: TestClock())
            let raw = ModelContext(container)

            #expect(try raw.fetchCount(FetchDescriptor<SessionTombstone>()) == 0)
            #expect(try store.exercises(includingArchived: true).count == 103)
            #expect(try store.routines(includingArchived: false).map(\.id) == [IDs.pushRoutine])

            // The finished session is still waiting for the phone's ack.
            let awaiting = try store.loggedSessionsAwaitingAck()
            #expect(awaiting.map(\.id) == [IDs.watchFinished])
            #expect(awaiting.first?.items.first?.sets.map(\.weightKg) == [100])

            // The in-flight one resumes with its scaffolding: the journal
            // row migrated with it.
            let resumable = try #require(try store.resumableActiveSession())
            #expect(resumable.session.id == IDs.watchActive)
            #expect(resumable.restTimer?.duration == 90)
            #expect(resumable.session.items.first?.sets.map(\.weightKg) == [102.5])

            let digest = try #require(try store.lastPerformance(exerciseID: IDs.bench))
            #expect(digest.sets.map(\.weightKg) == [100])
            #expect(try raw.fetchCount(FetchDescriptor<WatchSyncJournal>()) == 1)
            #expect(try raw.fetchCount(FetchDescriptor<CatalogSeedState>()) == 1)
        }
    }
}
