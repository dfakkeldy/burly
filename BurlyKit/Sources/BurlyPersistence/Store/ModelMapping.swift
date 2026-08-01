// SPDX-License-Identifier: GPL-3.0-or-later
// @Model → BurlyCore value type mapping. One direction only lives here;
// the other direction (value → model) needs the context, to resolve
// exercise references, so it lives in SwiftDataStore.
//
// Two invariants every `snapshot()` upholds:
//
// 1. **Ordering.** SwiftData to-many relationships are unordered sets. The
//    spec gives every child an explicit `order: Int`, so mapping sorts by
//    it. Without this, a cold reload could return the same graph in a
//    different sequence and §1 acceptance #1 would be a coin flip.
// 2. **Relationships become UUIDs.** `exercise: Exercise?` maps to
//    `exerciseID: UUID?` — cross-device references are by UUID, never by
//    object identity (architecture doc).

import Foundation
import SwiftData
import BurlyCore

extension Exercise {
    func snapshot() -> ExerciseData {
        ExerciseData(
            id: id,
            name: name,
            muscleGroups: muscleGroups,
            origin: origin,
            needsNaming: needsNaming,
            archivedAt: archivedAt
        )
    }
}

extension RoutineItem {
    func snapshot() -> RoutineItemData {
        RoutineItemData(
            id: id,
            exerciseID: exercise?.id,
            order: order,
            defaultSetCount: defaultSetCount,
            restOverride: restOverride,
            note: note
        )
    }
}

extension Routine {
    func snapshot() -> RoutineData {
        RoutineData(
            id: id,
            name: name,
            orderIndex: orderIndex,
            items: items.sorted { $0.order < $1.order }.map { $0.snapshot() },
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }
}

extension SetRecord {
    func snapshot() -> SetRecordData {
        SetRecordData(
            id: id,
            order: order,
            weight: Weight(kg: weightKg),
            reps: reps,
            isWarmup: isWarmup,
            completedAt: completedAt
        )
    }
}

extension SessionItem {
    func snapshot() -> SessionItemData {
        SessionItemData(
            id: id,
            exerciseID: exercise?.id,
            order: order,
            sets: sets.sorted { $0.order < $1.order }.map { $0.snapshot() }
        )
    }
}

extension Session {
    func snapshot() -> SessionData {
        SessionData(
            id: id,
            routineID: routineID,
            routineName: routineName,
            startedAt: startedAt,
            endedAt: endedAt,
            state: state,
            revision: revision,
            healthKitWorkoutID: healthKitWorkoutID,
            origin: origin,
            items: items.sorted { $0.order < $1.order }.map { $0.snapshot() },
            notes: notes
        )
    }
}

extension ExerciseLastPerformance {
    func snapshot() -> ExerciseLastPerformanceData {
        ExerciseLastPerformanceData(
            exerciseID: exerciseID,
            performedAt: performedAt,
            sets: sets
        )
    }
}
