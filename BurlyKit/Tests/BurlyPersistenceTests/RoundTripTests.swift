// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #1 — the round-trip gate.
//
// "create routine → start session → log sets → persist → cold-load
//  container → object graph identical."
//
// "Cold-load" is taken literally: the write container is torn down and a
// *new* `ModelContainer` is opened on the same store file. An in-memory
// container cannot prove this — it would only re-read the same live graph.

import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 #1 — round-trip: write, cold-load a new container, identical graph")
struct RoundTripTests {

    @Test("routine → session → logged sets survive a new container on the same store file")
    func fullGraphSurvivesColdLoad() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press", muscleGroups: [.chest, .triceps, .shoulders])
        let row = Fixture.exercise(name: "Barbell Row", muscleGroups: [.upperBack, .lats, .biceps])
        let routine = Fixture.routine(over: [bench, row])
        let session = Fixture.session(from: routine)

        let benchItemID = try #require(session.items.first { $0.exerciseID == bench.id }?.id)
        let rowItemID = try #require(session.items.first { $0.exerciseID == row.id }?.id)

        let benchSets = (0..<3).map { index in
            SetRecordData(
                order: index,
                weight: Weight(kg: 60 + Double(index) * 5),
                reps: 8 - index,
                isWarmup: index == 0,
                completedAt: Fixture.epoch.addingTimeInterval(Double(index) * 180)
            )
        }
        let rowSets = (0..<2).map { index in
            SetRecordData(
                order: index,
                weight: Weight(kg: 70),
                reps: 10,
                completedAt: Fixture.epoch.addingTimeInterval(1000 + Double(index) * 180)
            )
        }

        // ---- write, then let the writing container go out of scope ----
        let expectedRoutine: RoutineData
        let expectedSession: SessionData
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)
            try store.createSession(session)
            for set in benchSets { try store.logSet(set, toSessionItem: benchItemID) }
            for set in rowSets { try store.logSet(set, toSessionItem: rowItemID) }

            expectedRoutine = try #require(try store.routine(id: routine.id))
            expectedSession = try #require(try store.session(id: session.id))
        }

        // ---- cold load: brand-new container over the same file ----
        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))

        #expect(try reloaded.exercise(id: bench.id) == bench)
        #expect(try reloaded.exercise(id: row.id) == row)
        #expect(try reloaded.routine(id: routine.id) == expectedRoutine)
        #expect(try reloaded.session(id: session.id) == expectedSession)

        // …and identical to what was constructed, not merely self-consistent.
        let loadedRoutine = try #require(try reloaded.routine(id: routine.id))
        #expect(loadedRoutine == routine)

        let loadedSession = try #require(try reloaded.session(id: session.id))
        #expect(loadedSession.routineID == routine.id)
        #expect(loadedSession.routineName == routine.name)
        #expect(loadedSession.state == .active)
        #expect(loadedSession.revision == 1)
        #expect(loadedSession.items.map(\.order) == [0, 1])
        #expect(loadedSession.items[0].sets == benchSets)
        #expect(loadedSession.items[1].sets == rowSets)
    }

    @Test("child ordering is restored from `order`, not from insertion sequence")
    func childrenComeBackInOrder() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads, .glutes])
        let routine = Fixture.routine(over: [squat])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        // Logged deliberately out of order: 2, 0, 3, 1.
        let shuffledOrders = [2, 0, 3, 1]
        let sets = shuffledOrders.map { order in
            SetRecordData(
                order: order,
                weight: Weight(kg: 100 + Double(order)),
                reps: 5,
                completedAt: Fixture.epoch.addingTimeInterval(Double(order))
            )
        }

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(squat)
            try store.createRoutine(routine)
            try store.createSession(session)
            for set in sets { try store.logSet(set, toSessionItem: itemID) }
        }

        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))
        let loaded = try #require(try reloaded.session(id: session.id))
        #expect(loaded.items[0].sets.map(\.order) == [0, 1, 2, 3])
        #expect(loaded.items[0].sets.map(\.weightKg) == [100, 101, 102, 103])
    }

    @Test("in-memory store round-trips the same graph (the fast path tests use)")
    func inMemoryRoundTrip() throws {
        let store = try makeStore()
        let press = Fixture.exercise(name: "Overhead Press", muscleGroups: [.shoulders, .triceps])
        let routine = Fixture.routine(name: "Press day", over: [press])
        let session = Fixture.session(from: routine)

        try store.createExercise(press)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(try store.routine(id: routine.id) == routine)
        #expect(try store.session(id: session.id) == session)
    }

    @Test("§1 #4 — a weight entered in pounds is stored as kg and reads back as kg")
    func poundsNeverReachTheStore() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        let routine = Fixture.routine(name: "Arms", over: [curl])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        // The only way to give the store a weight is `Weight`, and the only
        // pound-shaped inputs it has convert on construction.
        let fromPounds = Weight(pounds: 135)
        let fromMeasurement = Weight(Measurement(value: 225, unit: UnitMass.pounds))

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(curl)
            try store.createRoutine(routine)
            try store.createSession(session)
            try store.logSet(
                SetRecordData(order: 0, weight: fromPounds, reps: 10, completedAt: Fixture.epoch),
                toSessionItem: itemID
            )
            try store.logSet(
                SetRecordData(order: 1, weight: fromMeasurement, reps: 5, completedAt: Fixture.epoch),
                toSessionItem: itemID
            )
        }

        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))
        let sets = try #require(try reloaded.session(id: session.id)).items[0].sets
        // Hand-computed: 135 × 0.45359237 and 225 × 0.45359237.
        #expect(abs(sets[0].weightKg - 61.234_969_95) < 0.000_001)
        #expect(abs(sets[1].weightKg - 102.058_283_25) < 0.000_001)
        // Round-trip back to the display unit is lossless, so nothing is
        // gained by ever storing lb.
        #expect(abs(sets[0].weight.pounds - 135) < 0.000_001)
        #expect(abs(sets[1].weight.pounds - 225) < 0.000_001)
    }
}
