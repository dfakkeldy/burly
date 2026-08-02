// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #2 — the cascade gate.
//
// "deleting Session removes its items/sets; deleting Routine removes
//  RoutineItems but leaves Exercises and past Sessions untouched."
//
// The store API returns value types, so "removed" is asserted against the
// underlying rows via a `@testable` fetch — otherwise a cascade that
// orphaned children instead of deleting them would still look clean.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 #2 — cascade deletes")
struct CascadeTests {

    /// Counts live rows of a model type directly, bypassing the store API.
    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    @Test("deleting a Session removes its SessionItems and SetRecords")
    func deletingSessionCascadesItemsAndSets() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        let empty = Fixture.session(from: routine)
        let firstItemID = try #require(empty.items.first?.id)
        let session = (0..<3).reduce(empty) { partial, index in
            partial.addingSet(
                SetRecordData(
                    order: index,
                    weight: Weight(kg: 80),
                    reps: 5,
                    completedAt: Fixture.epoch.addingTimeInterval(Double(index))
                ),
                toItem: firstItemID
            )
        }

        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(try rowCount(SessionItem.self, in: container) == 2)
        #expect(try rowCount(SetRecord.self, in: container) == 3)

        try store.deleteSession(id: session.id)

        #expect(try store.session(id: session.id) == nil)
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionItem.self, in: container) == 0)
        #expect(try rowCount(SetRecord.self, in: container) == 0)
        // The exercises the session referenced are untouched.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try store.exercise(id: bench.id) == bench)
    }

    @Test("deleting a Session returns its healthKitWorkoutID so the caller can delete the HKWorkout")
    func deletingSessionHandsBackTheWorkoutLink() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        let workoutID = UUID()
        var session = Fixture.session(from: routine)
        session.healthKitWorkoutID = workoutID

        try store.createExercise(squat)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(try store.deleteSession(id: session.id) == workoutID)
    }

    @Test("deleting a Session with no HK link returns nil rather than failing")
    func deletingUnlinkedSessionReturnsNil() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        let session = Fixture.session(from: routine)

        try store.createExercise(squat)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(try store.deleteSession(id: session.id) == nil)
    }

    @Test("deleting a Routine removes its RoutineItems but leaves Exercises and past Sessions untouched")
    func deletingRoutineCascadesItemsOnly() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        let empty = Fixture.session(from: routine)
        let firstItemID = try #require(empty.items.first?.id)
        let session = empty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 90), reps: 5, completedAt: Fixture.epoch),
            toItem: firstItemID
        )

        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(try rowCount(RoutineItem.self, in: container) == 2)

        try store.deleteRoutine(id: routine.id)

        #expect(try store.routine(id: routine.id) == nil)
        #expect(try rowCount(Routine.self, in: container) == 0)
        #expect(try rowCount(RoutineItem.self, in: container) == 0)

        // Exercises: untouched.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try store.exercise(id: bench.id) == bench)
        #expect(try store.exercise(id: row.id) == row)

        // Past session: untouched, including its denormalized provenance —
        // which is exactly why Session holds no relationship to Routine.
        let survivor = try #require(try store.session(id: session.id))
        #expect(survivor.routineID == routine.id)
        #expect(survivor.routineName == routine.name)
        #expect(survivor.items.count == 2)
        #expect(survivor.items[0].sets.count == 1)
        #expect(survivor.items[0].exerciseID == bench.id)
        #expect(try rowCount(SetRecord.self, in: container) == 1)
    }

    @Test("deleting one Session leaves other sessions and their sets alone")
    func deletingOneSessionIsScoped() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)

        let deadlift = Fixture.exercise(name: "Deadlift", muscleGroups: [.hamstrings, .glutes])
        let routine = Fixture.routine(over: [deadlift])
        try store.createExercise(deadlift)
        try store.createRoutine(routine)

        let emptyKeeper = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let keeper = emptyKeeper.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 140), reps: 3, completedAt: Fixture.epoch),
            toItem: try #require(emptyKeeper.items.first?.id)
        )
        let emptyDoomed = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        let doomed = emptyDoomed.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 145), reps: 3, completedAt: Fixture.epoch),
            toItem: try #require(emptyDoomed.items.first?.id)
        )
        try store.createSession(keeper)
        try store.createSession(doomed)

        try store.deleteSession(id: doomed.id)

        #expect(try rowCount(Session.self, in: container) == 1)
        #expect(try rowCount(SessionItem.self, in: container) == 1)
        #expect(try rowCount(SetRecord.self, in: container) == 1)
        let survivor = try #require(try store.session(id: keeper.id))
        #expect(survivor.items[0].sets[0].weightKg == 140)
    }

    /// The other cascade tests in this file run entirely in-memory: a
    /// cascade that merely *orphaned* children (nulled their parent link
    /// instead of deleting the rows) could still look clean against the same
    /// live `ModelContext` that performed the delete. Reopening a brand-new
    /// container on the same store file rules that out — there is no shared
    /// in-memory state left to coincidentally agree with the assertions.
    @Test("a Session's cascade survives a disk-backed cold reopen: cascaded SessionItems and SetRecords are genuinely gone, not just orphaned in the live context")
    func deletingSessionCascadeSurvivesDiskColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        let empty = Fixture.session(from: routine)
        let firstItemID = try #require(empty.items.first?.id)
        let secondItemID = try #require(empty.items.last?.id)
        let sets = (0..<3).map { index in
            SetRecordData(
                order: index,
                weight: Weight(kg: 80),
                reps: 5,
                completedAt: Fixture.epoch.addingTimeInterval(Double(index))
            )
        }
        let setIDs = sets.map(\.id)
        let session = sets.reduce(empty) { $0.addingSet($1, toItem: firstItemID) }

        // ---- write, delete, then let the writing container go out of scope ----
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)
            try store.createSession(session)

            #expect(try store.session(id: session.id) != nil)
            try store.deleteSession(id: session.id)
        }

        // ---- cold open: a brand-new container/store over the same file ----
        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)

        #expect(try reopened.session(id: session.id) == nil)
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionItem.self, in: container) == 0)
        #expect(try rowCount(SetRecord.self, in: container) == 0)

        // Fetch by the deleted ids directly, not just by count — counting
        // alone couldn't tell a correct cascade from one that dropped the
        // wrong rows but landed on the same totals.
        let context = ModelContext(container)
        for id in [firstItemID, secondItemID] {
            let descriptor = FetchDescriptor<SessionItem>(predicate: #Predicate { $0.id == id })
            #expect(try context.fetch(descriptor).isEmpty)
        }
        for id in setIDs {
            let descriptor = FetchDescriptor<SetRecord>(predicate: #Predicate { $0.id == id })
            #expect(try context.fetch(descriptor).isEmpty)
        }

        // The exercises the session referenced are untouched, on disk too.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try reopened.exercise(id: bench.id) == bench)
        #expect(try reopened.exercise(id: row.id) == row)
    }

    /// Mirrors `deletingSessionCascadeSurvivesDiskColdReopen` above for
    /// `deleteRoutine` (m1-04 review): the in-memory
    /// `deletingRoutineCascadesItemsOnly` test above could pass even if the
    /// cascade only orphaned `RoutineItem` rows in the live context instead
    /// of genuinely deleting them, since nothing forces a fresh fetch
    /// against anything but that same live `ModelContext`. A brand-new
    /// container over the same store file rules that out.
    @Test("a Routine's cascade survives a disk-backed cold reopen: cascaded RoutineItems are genuinely gone, not just orphaned in the live context; Exercises and past Sessions survive")
    func deletingRoutineCascadeSurvivesDiskColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        let empty = Fixture.session(from: routine)
        let firstItemID = try #require(empty.items.first?.id)
        let session = empty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 90), reps: 5, completedAt: Fixture.epoch),
            toItem: firstItemID
        )
        let routineItemIDs = routine.items.map(\.id)

        // ---- write, delete, then let the writing container go out of scope ----
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)
            try store.createSession(session)

            #expect(try store.routine(id: routine.id) != nil)
            try store.deleteRoutine(id: routine.id)
        }

        // ---- cold open: a brand-new container/store over the same file ----
        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)

        #expect(try reopened.routine(id: routine.id) == nil)
        #expect(try rowCount(Routine.self, in: container) == 0)
        #expect(try rowCount(RoutineItem.self, in: container) == 0)

        // Fetch by the deleted RoutineItem ids directly, not just by count —
        // counting alone couldn't tell a correct cascade from one that
        // dropped the wrong rows but landed on the same totals.
        let context = ModelContext(container)
        for id in routineItemIDs {
            let descriptor = FetchDescriptor<RoutineItem>(predicate: #Predicate { $0.id == id })
            #expect(try context.fetch(descriptor).isEmpty)
        }

        // The exercises the routine referenced are untouched, on disk too.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try reopened.exercise(id: bench.id) == bench)
        #expect(try reopened.exercise(id: row.id) == row)

        // The past session survives, with its denormalized routine
        // provenance, its own items, and its logged set intact — exactly
        // why Session holds no relationship to Routine.
        let survivor = try #require(try reopened.session(id: session.id))
        #expect(survivor.routineID == routine.id)
        #expect(survivor.routineName == routine.name)
        #expect(survivor.items.count == 2)
        #expect(survivor.items[0].sets.count == 1)
        #expect(survivor.items[0].exerciseID == bench.id)
        #expect(try rowCount(Session.self, in: container) == 1)
        #expect(try rowCount(SessionItem.self, in: container) == 2)
        #expect(try rowCount(SetRecord.self, in: container) == 1)
    }
}
