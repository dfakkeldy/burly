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
    /// Validates the stored `weightKg` column on read-back instead of
    /// trusting it (m1-06 review, finding M5): it is a plain `Double`
    /// column, so `Weight`'s finite/non-negative invariant is otherwise
    /// unenforced once a value is on disk — a hostile-data boundary no
    /// different in kind from Decodable, just reached by a different route.
    /// Throws `BurlyStoreError.corruptedWeight` instead of ever handing a
    /// poisoned `Weight` back into equality, sorting, volume, PR, or chart
    /// math; never traps, since a corrupted row is data, not a caller bug.
    ///
    /// ## Accepted limitation: a stored NaN heals to bodyweight
    ///
    /// This catches exactly the corruption classes that *survive storage*.
    /// Negative and infinite values do, and fail closed here. `NaN` does
    /// not: SwiftData's SQLite `REAL` column cannot represent it, and the
    /// value reads back as `0.0` — indistinguishable from a legitimately
    /// logged bodyweight set, which §1 says 0 kg is. By the time this
    /// function sees the column the evidence is gone, so no check placed
    /// here (or anywhere downstream) can tell the two apart, and detection
    /// after the fact is not merely missing but impossible. Measured and
    /// pinned by `storedNaNHealsToZeroOnColdReload` in
    /// Tests/BurlyPersistenceTests/StoreAPISurfaceTests.swift (m1-06 review
    /// round D).
    ///
    /// Accepted rather than engineered around. Reaching a stored NaN
    /// requires an out-of-band writer — the store's own write paths cannot
    /// produce one, since `Weight` traps or throws first — and the harm it
    /// does after healing is bounded: one set reads as bodyweight instead
    /// of its real load, rather than poisoning every aggregate that touches
    /// it the way a surviving NaN would. Distinguishing the two would mean
    /// storing a checksum or a redundant encoding of every weight column
    /// against a threat the API surface already excludes.
    func snapshot() throws -> SetRecordData {
        do {
            return SetRecordData(
                id: id,
                order: order,
                weight: try Weight(validatingKg: weightKg),
                reps: reps,
                isWarmup: isWarmup,
                completedAt: completedAt
            )
        } catch let error as WeightValidationError {
            throw BurlyStoreError.corruptedWeight(id: id, underlying: error)
        }
    }
}

extension SessionItem {
    /// `throws` only because a `SetRecord` under it can fail the read-back
    /// validation above; the error propagates unchanged.
    func snapshot() throws -> SessionItemData {
        SessionItemData(
            id: id,
            exerciseID: exercise?.id,
            order: order,
            sets: try sets.sorted { $0.order < $1.order }.map { try $0.snapshot() }
        )
    }
}

extension Session {
    /// `throws` only because a `SessionItem`/`SetRecord` under it can fail
    /// the read-back validation in `SetRecord.snapshot()`; the error
    /// propagates unchanged.
    func snapshot() throws -> SessionData {
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
            items: try items.sorted { $0.order < $1.order }.map { try $0.snapshot() },
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
