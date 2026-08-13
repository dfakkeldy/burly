// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BurlyPersistence
import BurlyCore

@Suite("Exercise naming queue")
@MainActor
struct ExerciseNamingTests {
    @Test("merging a placeholder repoints logged session items and archives it")
    func mergingPlaceholderRepointsHistory() throws {
        let store = try makeStore()
        let placeholder = ExerciseData(name: "Custom", muscleGroups: [], origin: .custom, needsNaming: true)
        let existing = ExerciseData(name: "Barbell Row", muscleGroups: [], origin: .curated)
        try store.createExercise(placeholder)
        try store.createExercise(existing)

        let set = SetRecordData(order: 0, weight: Weight(kg: 60), reps: 8, completedAt: Date())
        let session = SessionData(
            routineName: "Pull",
            startedAt: Date(),
            endedAt: Date(),
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: placeholder.id, order: 0, sets: [set])]
        )
        try store.createSession(session)

        try store.mergePlaceholderExercise(id: placeholder.id, into: existing.id, at: Date(timeIntervalSince1970: 1))

        #expect(try store.session(id: session.id)?.items.first?.exerciseID == existing.id)
        let archivedPlaceholder = try #require(try store.exercise(id: placeholder.id))
        #expect(archivedPlaceholder.needsNaming)
        #expect(archivedPlaceholder.archivedAt == Date(timeIntervalSince1970: 1))
    }

    @Test("a phone set edit preserves the linked HealthKit workout identifier")
    func phoneEditPreservesHealthKitLink() throws {
        let store = try makeStore()
        let exercise = ExerciseData(name: "Deadlift", muscleGroups: [], origin: .curated)
        try store.createExercise(exercise)
        let workoutID = UUID()
        var session = SessionData(
            startedAt: Date(), endedAt: Date(), state: .logged, healthKitWorkoutID: workoutID, origin: .live,
            items: [SessionItemData(exerciseID: exercise.id, order: 0, sets: [SetRecordData(order: 0, weight: Weight(kg: 80), reps: 5, completedAt: Date())])]
        )
        try store.createSession(session)
        session.items[0].sets[0].reps = 6

        _ = try store.applyPhoneEdit(session)

        #expect(try store.session(id: session.id)?.healthKitWorkoutID == workoutID)
    }
}
