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
        let session = Fixture.session(from: routine)
        let firstItemID = try #require(session.items.first?.id)

        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)
        try store.createSession(session)
        for index in 0..<3 {
            try store.logSet(
                SetRecordData(
                    order: index,
                    weight: Weight(kg: 80),
                    reps: 5,
                    completedAt: Fixture.epoch.addingTimeInterval(Double(index))
                ),
                toSessionItem: firstItemID
            )
        }

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
        let session = Fixture.session(from: routine)
        let firstItemID = try #require(session.items.first?.id)

        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 90), reps: 5, completedAt: Fixture.epoch),
            toSessionItem: firstItemID
        )

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

        let keeper = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let doomed = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        try store.createSession(keeper)
        try store.createSession(doomed)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 140), reps: 3, completedAt: Fixture.epoch),
            toSessionItem: try #require(keeper.items.first?.id)
        )
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 145), reps: 3, completedAt: Fixture.epoch),
            toSessionItem: try #require(doomed.items.first?.id)
        )

        try store.deleteSession(id: doomed.id)

        #expect(try rowCount(Session.self, in: container) == 1)
        #expect(try rowCount(SessionItem.self, in: container) == 1)
        #expect(try rowCount(SetRecord.self, in: container) == 1)
        let survivor = try #require(try store.session(id: keeper.id))
        #expect(survivor.items[0].sets[0].weightKg == 140)
    }
}
