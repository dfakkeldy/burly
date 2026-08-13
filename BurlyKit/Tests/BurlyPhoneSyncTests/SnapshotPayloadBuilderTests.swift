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
}
