// SPDX-License-Identifier: MIT
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlyPhoneSync
import BurlySync

@Suite("Snapshot payload construction")
struct SnapshotPayloadBuilderTests {
    @Test("an archived exercise referenced by a live routine remains in the snapshot and applies on the watch")
    @MainActor
    func archivedReferencedExerciseRemainsAvailableToWatchRoutine() throws {
        let phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        let exercise = ExerciseData(name: "Archived", muscleGroups: [.biceps], origin: .custom)
        let routine = RoutineData(name: "Live", orderIndex: 0, items: [RoutineItemData(exerciseID: exercise.id, order: 0, defaultSetCount: 3)], updatedAt: .now)
        try phone.createExercise(exercise)
        try phone.createRoutine(routine)
        try phone.archiveExercise(id: exercise.id, at: .now)

        let snapshot = try SnapshotPayloadBuilder.build(version: 3, from: phone)
        #expect(snapshot.exercises.map(\.id) == [exercise.id])
        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        #expect(try watch.replaceWatchWorkingSet(snapshot))
        #expect(try watch.routine(id: routine.id)?.items.first?.exerciseID == exercise.id)
    }

    @Test("an exercise archived on the phone after the watch has it is archived on the watch and leaves its picker")
    @MainActor
    func phoneArchiveReachesWatchPicker() throws {
        let phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        let kept = ExerciseData(name: "Kept", muscleGroups: [.chest], origin: .curated)
        let archived = ExerciseData(name: "Old Custom", muscleGroups: [.biceps], origin: .custom)
        try phone.createExercise(kept)
        try phone.createExercise(archived)

        #expect(try watch.replaceWatchWorkingSet(SnapshotPayloadBuilder.build(version: 1, from: phone)))
        #expect(try watch.exercises(includingArchived: false).map(\.id).contains(archived.id))

        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try phone.archiveExercise(id: archived.id, at: archivedAt)
        let snapshot = try SnapshotPayloadBuilder.build(version: 2, from: phone)
        // No routine references it, and it is still sent: §5's full catalog.
        #expect(Set(snapshot.exercises.map(\.id)) == [kept.id, archived.id])
        #expect(try watch.replaceWatchWorkingSet(snapshot))

        // The watch's swap/add picker lists exactly this query
        // (`SessionViewModel`'s catalog source).
        #expect(try watch.exercises(includingArchived: false).map(\.id) == [kept.id])
        #expect(try watch.exercise(id: archived.id)?.archivedAt == archivedAt)
    }

    @Test("a placeholder merged on the phone is archived on the watch, so it cannot be picked again")
    @MainActor
    func mergedPlaceholderLeavesWatchPicker() throws {
        let phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        let real = ExerciseData(name: "Cable Fly", muscleGroups: [.chest], origin: .curated)
        let placeholder = ExerciseData(name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true)
        // The watch created the placeholder mid-session; the phone ingested
        // it with that session, and its next snapshot carries it back.
        try watch.createExercise(placeholder)
        try phone.createExercise(real)
        try phone.createExercise(placeholder)
        #expect(try watch.replaceWatchWorkingSet(SnapshotPayloadBuilder.build(version: 1, from: phone)))
        #expect(Set(try watch.exercises(includingArchived: false).map(\.id)) == [real.id, placeholder.id])

        try phone.mergePlaceholderExercise(id: placeholder.id, into: real.id, at: .now)
        #expect(try watch.replaceWatchWorkingSet(SnapshotPayloadBuilder.build(version: 2, from: phone)))

        #expect(try watch.exercises(includingArchived: false).map(\.id) == [real.id])
        #expect(try watch.exercise(id: placeholder.id)?.archivedAt != nil)
    }

    @Test("a placeholder the phone has not ingested yet survives a snapshot that does not name it")
    @MainActor
    func uningestedPlaceholderSurvivesSnapshot() throws {
        let phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        let real = ExerciseData(name: "Cable Fly", muscleGroups: [.chest], origin: .curated)
        let placeholder = ExerciseData(name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true)
        try phone.createExercise(real)
        try watch.createExercise(placeholder)

        #expect(try watch.replaceWatchWorkingSet(SnapshotPayloadBuilder.build(version: 1, from: phone)))

        #expect(Set(try watch.exercises(includingArchived: false).map(\.id)) == [real.id, placeholder.id])
    }
}
