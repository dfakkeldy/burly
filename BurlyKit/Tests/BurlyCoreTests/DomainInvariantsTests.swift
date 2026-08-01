// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

@Suite("Domain invariants")
struct DomainInvariantsTests {
    @Test("SetRecordData can represent a bodyweight set (0 kg), per the documented convention")
    func setRecordRepresentsBodyweight() {
        let set = SetRecordData(order: 0, weight: .bodyweight, reps: 12, completedAt: Date())
        #expect(set.weightKg == 0)
        #expect(set.weight == Weight.bodyweight)
    }

    @Test("SetSnapshot can represent a bodyweight set (0 kg)")
    func snapshotRepresentsBodyweight() {
        let snapshot = SetSnapshot(weight: .bodyweight, reps: 10)
        #expect(snapshot.weightKg == 0)
    }

    @Test("SetRecordData.setWeight(_:) only ever accepts a Weight, updating weightKg accordingly")
    func setWeightMutatorGoesThroughWeight() {
        var set = SetRecordData(order: 0, weight: .bodyweight, reps: 5, completedAt: Date())
        set.setWeight(Weight(pounds: 100))
        #expect(abs(set.weightKg - Weight(pounds: 100).kg) < 1e-9)
    }

    @Test("SessionData defaults to revision 1 and .active state, per spec §1")
    func sessionDefaults() {
        let session = SessionData(startedAt: Date(), origin: .live)
        #expect(session.revision == 1)
        #expect(session.state == .active)
        #expect(session.items.isEmpty)
    }

    @Test("RoutineItemData defaults defaultSetCount to 3, per spec §1")
    func routineItemDefaultSetCount() {
        let item = RoutineItemData(exerciseID: nil, order: 0)
        #expect(item.defaultSetCount == 3)
    }

    @Test("SetRecordData defaults isWarmup to false, per spec §1")
    func setRecordDefaultIsWarmup() {
        let set = SetRecordData(order: 0, weight: .bodyweight, reps: 1, completedAt: Date())
        #expect(set.isWarmup == false)
    }

    @Test("ExerciseData defaults needsNaming to false and archivedAt to nil")
    func exerciseDataDefaults() {
        let exercise = ExerciseData(name: "Deadlift", muscleGroups: [.hamstrings, .lats], origin: .curated)
        #expect(exercise.needsNaming == false)
        #expect(exercise.archivedAt == nil)
    }

    @Test("RoutineData and SessionData default their embedded collections to empty")
    func embeddedCollectionsDefaultEmpty() {
        let routine = RoutineData(name: "Empty Routine", orderIndex: 0, updatedAt: Date())
        #expect(routine.items.isEmpty)

        let session = SessionData(startedAt: Date(), origin: .live)
        #expect(session.items.isEmpty)
    }
}
