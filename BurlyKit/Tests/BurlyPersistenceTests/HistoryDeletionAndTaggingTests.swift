// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's history delete (§1 deletion rule, §6 "deleting the session")
// and the exercise muscle-tag writes the naming queue and the catalog use.
//
// `deleteLoggedSession` is `deleteSession` plus a tombstone, and the
// tombstone is the part that needs proving: the watch re-sends a session
// until a digest acks it, so the replicated apply must treat a deleted id
// as settled rather than new. Row-level assertions go through a
// `@testable` context for the same reason CascadeTests does: the store API
// returns values, so an orphaned child would otherwise look clean.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@MainActor
@Suite("Phone history delete (tombstoned) and exercise muscle tags")
struct HistoryDeletionAndTaggingTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    /// A logged session with two sets on one item, linked to a workout.
    private func seededSession(in store: SwiftDataStore, workoutID: UUID? = UUID()) throws -> SessionData {
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads, .glutes])
        let routine = Fixture.routine(over: [squat])
        let empty = Fixture.session(from: routine)
        let itemID = try #require(empty.items.first?.id)
        var session = (0..<2).reduce(empty) { partial, index in
            partial.addingSet(
                SetRecordData(order: index, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch.addingTimeInterval(Double(index))),
                toItem: itemID
            )
        }
        session.healthKitWorkoutID = workoutID
        try store.createExercise(squat)
        try store.createSession(session)
        return session
    }

    // MARK: - deleteLoggedSession

    @Test("deleteLoggedSession cascades items and sets, returns the workout link, and records one tombstone")
    func deleteLoggedSessionCascadesAndTombstones() throws {
        let clock = TestClock()
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container, clock: clock)
        let workoutID = UUID()
        let session = try seededSession(in: store, workoutID: workoutID)
        #expect(try rowCount(SetRecord.self, in: container) == 2)

        clock.advance(by: 3600)
        #expect(try store.deleteLoggedSession(id: session.id) == workoutID)

        #expect(try store.session(id: session.id) == nil)
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionItem.self, in: container) == 0)
        #expect(try rowCount(SetRecord.self, in: container) == 0)
        // History integrity (§1): the exercise outlives the session.
        #expect(try rowCount(Exercise.self, in: container) == 1)

        let tombstones = try ModelContext(container).fetch(FetchDescriptor<SessionTombstone>())
        #expect(tombstones.map(\.sessionID) == [session.id])
        #expect(tombstones.first?.deletedAt == clock.now, "the store stamps its own clock")
    }

    @Test("deleteLoggedSession on an unknown id throws notFound and writes no tombstone")
    func deleteLoggedSessionUnknownIDWritesNothing() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)
        let ghost = UUID()

        #expect(throws: BurlyStoreError.notFound(ghost)) {
            try store.deleteLoggedSession(id: ghost)
        }
        #expect(try rowCount(SessionTombstone.self, in: container) == 0)
    }

    @Test("a replicated re-delivery of a deleted session is a no-op: no session, no placeholder, incoming revision returned")
    func tombstonedRedeliveryWritesNothing() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)
        let session = try seededSession(in: store)
        try store.deleteLoggedSession(id: session.id)

        // The watch's copy, still in its outbox, now carrying a placeholder
        // the phone has never seen (it rode with the original delivery and
        // the user merged it away, say). Neither may come back.
        let placeholder = ExerciseData(name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true)
        var redelivered = session
        redelivered.items.append(SessionItemData(exerciseID: placeholder.id, order: 1))

        let returned = try store.applyReplicatedSession(redelivered, upsertingPlaceholderExercises: [placeholder])

        #expect(returned == redelivered.revision)
        #expect(try store.session(id: session.id) == nil)
        #expect(try store.exercise(id: placeholder.id) == nil, "an orphan placeholder would queue a naming prompt for deleted history")
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionTombstone.self, in: container) == 1)
    }

    @Test("a tombstone wins over a higher revision and over an .active claim, quietly")
    func tombstoneIsSettledWhateverThePayloadClaims() throws {
        let store = try makeStore()
        let session = try seededSession(in: store)
        try store.deleteLoggedSession(id: session.id)

        var bumped = session
        bumped.revision = 7
        #expect(try store.applyReplicatedSession(bumped) == 7)
        #expect(try store.session(id: session.id) == nil)

        // A stale payload claiming `.active` is unreachable on today's
        // protocol, but major 8's rule applies: a settled id is owed a
        // quiet re-ack, never a throw the runtime would answer with silence.
        var active = session
        active.state = .active
        #expect(try store.applyReplicatedSession(active) == session.revision)
        #expect(try store.session(id: session.id) == nil)
    }

    @Test("the raw deleteSession leaves no tombstone, so a re-delivery recreates the session")
    func rawDeleteSessionStillAllowsReinsertion() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)
        let session = try seededSession(in: store)

        try store.deleteSession(id: session.id)
        #expect(try rowCount(SessionTombstone.self, in: container) == 0)

        try store.applyReplicatedSession(session)
        #expect(try store.session(id: session.id) == session)
    }

    @Test("a strict createSession ignores the tombstone: a deliberate re-import after a delete still lands")
    func strictCreateIgnoresTombstone() throws {
        let store = try makeStore()
        let session = try seededSession(in: store)
        try store.deleteLoggedSession(id: session.id)

        try store.createSession(session)
        #expect(try store.session(id: session.id) == session)
    }

    @Test("the tombstone is durable: after a cold reopen of the same file a re-delivery is still refused")
    func tombstoneSurvivesColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let session: SessionData
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            session = try seededSession(in: store)
            try store.deleteLoggedSession(id: session.id)
        }

        let reopened = try SwiftDataStore(kind: .phone, at: .file(url))
        try reopened.applyReplicatedSession(session)
        #expect(try reopened.session(id: session.id) == nil)
        #expect(try reopened.loggedSessionCount() == 0)
    }

    @Test("deleting the same session twice is refused the second time and leaves exactly one tombstone")
    func secondDeleteIsNotFound() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)
        let session = try seededSession(in: store)
        try store.deleteLoggedSession(id: session.id)

        #expect(throws: BurlyStoreError.notFound(session.id)) {
            try store.deleteLoggedSession(id: session.id)
        }
        #expect(try rowCount(SessionTombstone.self, in: container) == 1)
    }

    // MARK: - Muscle tags

    @Test("naming a placeholder writes the name, the muscle tags and needsNaming=false together, keeping its id")
    func namingAPlaceholderCollectsItsTags() throws {
        let store = try makeStore()
        let placeholder = ExerciseData(name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true)
        try store.createExercise(placeholder)

        try store.namePlaceholderExercise(id: placeholder.id, name: "Cable Fly", muscleGroups: [.chest, .shoulders])

        let named = try #require(try store.exercise(id: placeholder.id))
        #expect(named.name == "Cable Fly")
        #expect(named.muscleGroups == [.chest, .shoulders])
        #expect(named.needsNaming == false)
        #expect(named.origin == .custom)
        #expect(named.archivedAt == nil)
    }

    @Test("naming an unknown exercise throws notFound")
    func namingUnknownExerciseThrows() throws {
        let store = try makeStore()
        let ghost = UUID()
        #expect(throws: BurlyStoreError.notFound(ghost)) {
            try store.namePlaceholderExercise(id: ghost, name: "Anything", muscleGroups: [.core])
        }
    }

    @Test("retagging a Hevy-imported custom replaces its tags and nothing else, and its history follows")
    func retaggingAnImportedCustomChangesOnlyTags() throws {
        let store = try makeStore()
        let imported = ExerciseData(name: "Landmine Press", muscleGroups: [], origin: .hevyImport)
        try store.createExercise(imported)
        let set = SetRecordData(order: 0, weight: Weight(kg: 30), reps: 10, completedAt: Fixture.epoch)
        let session = SessionData(
            startedAt: Fixture.epoch, endedAt: Fixture.epoch, state: .logged, origin: .hevyImport,
            items: [SessionItemData(exerciseID: imported.id, order: 0, sets: [set])]
        )
        try store.createSession(session)
        try store.archiveExercise(id: imported.id, at: Fixture.epoch)

        try store.updateExerciseMuscleGroups(id: imported.id, muscleGroups: [.shoulders, .triceps])

        let stored = try #require(try store.exercise(id: imported.id))
        #expect(stored.muscleGroups == [.shoulders, .triceps])
        #expect(stored.name == "Landmine Press")
        #expect(stored.origin == .hevyImport)
        #expect(stored.needsNaming == false)
        #expect(stored.archivedAt == Fixture.epoch, "a retag must not un-archive")
        // Stats attribute through the exercise id, so the logged set is now
        // attributable without the session itself being rewritten.
        #expect(try store.session(id: session.id) == session)
        #expect(try store.loggedSetSlices(exerciseID: imported.id, since: nil, through: nil).count == 1)
    }

    @Test("retagging an unknown exercise throws notFound")
    func retaggingUnknownExerciseThrows() throws {
        let store = try makeStore()
        let ghost = UUID()
        #expect(throws: BurlyStoreError.notFound(ghost)) {
            try store.updateExerciseMuscleGroups(id: ghost, muscleGroups: [.core])
        }
    }
}
