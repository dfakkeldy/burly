// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #3 (shape) plus the archive semantics §1 and §9 rely on.
//
// Acceptance #3 — "attempting hard-delete of a referenced Exercise is
// impossible via the store API surface (no such method)" — is primarily a
// *compile-time* property: `BurlyStore` declares no delete for exercises, so
// the failing call cannot be written. The tests below cover what a test
// still can cover: that archive is the real path, and that the second lock
// (`.deny` on `Exercise`'s relationships) fires if someone reaches past the
// protocol into the context.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 #3 — archive, never delete; store API surface")
struct StoreAPISurfaceTests {

    @Test("archiving an Exercise keeps it and its history; it just leaves the pickers")
    func archivingExercisePreservesHistory() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let archivedAt = Fixture.epoch.addingTimeInterval(3600)
        try store.archiveExercise(id: bench.id, at: archivedAt)

        #expect(try store.exercises(includingArchived: false).isEmpty)
        #expect(try store.exercises(includingArchived: true).map(\.id) == [bench.id])
        #expect(try store.exercise(id: bench.id)?.archivedAt == archivedAt)

        // History still resolves to the exercise.
        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].exerciseID == bench.id)
        #expect(stored.items[0].sets.count == 1)
    }

    @Test("archiving a Routine hides it from the list but keeps it fetchable by id")
    func archivingRoutineHidesItFromTheList() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(name: "Legs", over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let archivedAt = Fixture.epoch.addingTimeInterval(60)
        try store.archiveRoutine(id: routine.id, at: archivedAt)

        #expect(try store.routines(includingArchived: false).isEmpty)
        #expect(try store.routines(includingArchived: true).map(\.id) == [routine.id])
        #expect(try store.routine(id: routine.id)?.archivedAt == archivedAt)
        #expect(try store.routine(id: routine.id)?.items.count == 1)
    }

    /// Pins a measured SwiftData behavior, not a Burly design choice.
    ///
    /// `Exercise` declares `.deny` on both inverse relationships, which
    /// *reads* as "a referenced exercise cannot be deleted". SwiftData does
    /// not honour it: the delete saves cleanly and behaves like `.nullify`,
    /// vaporising the exercise and orphaning the history that pointed at it.
    ///
    /// So this test documents the hazard rather than a protection: the
    /// absence of a delete method on `BurlyStore` is the *only* thing
    /// standing between §1's history-integrity rule and data loss. If a
    /// future SwiftData starts enforcing `.deny`, this test fails — update
    /// the comments in Models/Exercise.swift and Store/BurlyStore.swift then.
    @Test("SwiftData does not enforce `.deny` — API absence is the only guard on Exercise deletion")
    func denyRuleIsNotEnforcedBySwiftData() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)

        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)

        // Reaching past `BurlyStore` — only possible with @testable, and
        // exactly the mistake §1 acceptance #3 forbids by omitting the method.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = bench.id
        var descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let model = try #require(try context.fetch(descriptor).first)
        #expect(!model.routineItems.isEmpty)
        #expect(!model.sessionItems.isEmpty)

        context.delete(model)
        try context.save()

        let verifier = SwiftDataStore(container: container)
        #expect(try verifier.exercise(id: bench.id) == nil)
        #expect(try verifier.session(id: session.id)?.items[0].exerciseID == nil)
        #expect(try verifier.routine(id: routine.id)?.items[0].exerciseID == nil)
    }

    @Test("creates are strict: a duplicate id throws rather than silently upserting")
    func duplicateCreatesThrow() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)

        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(throws: BurlyStoreError.duplicateID(bench.id)) {
            try store.createExercise(Fixture.exercise(id: bench.id, name: "Bench Press (dupe)"))
        }
        #expect(throws: BurlyStoreError.duplicateID(routine.id)) {
            try store.createRoutine(routine)
        }
        #expect(throws: BurlyStoreError.duplicateID(session.id)) {
            try store.createSession(session)
        }
        // The original name survived — no silent overwrite.
        #expect(try store.exercise(id: bench.id)?.name == "Bench Press")
    }

    @Test("a routine or session item naming an unknown exercise is rejected, not stored dangling")
    func danglingExerciseReferencesAreRejected() throws {
        let store = try makeStore()
        let ghostID = UUID()
        let routine = RoutineData(
            name: "Broken",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: ghostID, order: 0)],
            updatedAt: Fixture.epoch
        )

        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.createRoutine(routine)
        }

        let session = SessionData(
            startedAt: Fixture.epoch,
            origin: .live,
            items: [SessionItemData(exerciseID: ghostID, order: 0)]
        )
        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.createSession(session)
        }
    }

    @Test("a nil exercise reference is allowed — the spec's relationships are optional")
    func nilExerciseReferenceIsAllowed() throws {
        let store = try makeStore()
        let routine = RoutineData(
            name: "Placeholder day",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: nil, order: 0)],
            updatedAt: Fixture.epoch
        )
        try store.createRoutine(routine)
        #expect(try store.routine(id: routine.id) == routine)
    }

    @Test("mutating an absent record throws notFound instead of failing silently")
    func absentRecordsThrowNotFound() throws {
        let store = try makeStore()
        let ghostID = UUID()

        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.archiveExercise(id: ghostID, at: Fixture.epoch)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.archiveRoutine(id: ghostID, at: Fixture.epoch)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.deleteRoutine(id: ghostID)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.deleteSession(id: ghostID)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.logSet(
                SetRecordData(order: 0, weight: .bodyweight, reps: 10, completedAt: Fixture.epoch),
                toSessionItem: ghostID
            )
        }
        #expect(try store.exercise(id: ghostID) == nil)
        #expect(try store.routine(id: ghostID) == nil)
        #expect(try store.session(id: ghostID) == nil)
        #expect(try store.lastPerformance(exerciseID: ghostID) == nil)
    }

    @Test("list fetches use the spec's orderings")
    func listOrderings() throws {
        let store = try makeStore()
        let zercher = Fixture.exercise(name: "Zercher Squat", muscleGroups: [.quads])
        let arnold = Fixture.exercise(name: "Arnold Press", muscleGroups: [.shoulders])
        try store.createExercise(zercher)
        try store.createExercise(arnold)
        // §9: catalog browsing is alphabetical.
        #expect(try store.exercises(includingArchived: false).map(\.name) == ["Arnold Press", "Zercher Squat"])

        let second = Fixture.routine(name: "B", orderIndex: 1, over: [arnold])
        let first = Fixture.routine(name: "A", orderIndex: 0, over: [zercher])
        try store.createRoutine(second)
        try store.createRoutine(first)
        // §9: routines are in the user's manual order.
        #expect(try store.routines(includingArchived: false).map(\.name) == ["A", "B"])

        let older = Fixture.session(from: first, startedAt: Fixture.epoch)
        let newer = Fixture.session(from: first, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        try store.createSession(older)
        try store.createSession(newer)
        // §6: history is reverse-chronological.
        #expect(try store.sessions().map(\.id) == [newer.id, older.id])
    }

    @Test("a 0 kg set is the bodyweight convention, stored and read back as 0")
    func bodyweightIsZeroKilograms() throws {
        let store = try makeStore()
        let pullUp = Fixture.exercise(name: "Pull-up", muscleGroups: [.lats])
        let routine = Fixture.routine(over: [pullUp])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        try store.createExercise(pullUp)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: .bodyweight, reps: 12, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].sets[0].weightKg == 0)
    }
}
