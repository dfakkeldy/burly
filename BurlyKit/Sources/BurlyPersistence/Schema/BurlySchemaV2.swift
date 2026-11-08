// SPDX-License-Identifier: MIT
// BurlySchemaV2 — V1 plus `SessionTombstone`, the phone's record of a
// deleted session (Models/SessionTombstone.swift).
//
// V1 shipped in TestFlight 0.9.1 (burly-rc1), so its declarations in
// Models/ are frozen: a store that build created has V1's exact shape, and
// a V1 edited in place would match no version in `BurlyMigrationPlan`, so
// SwiftData would refuse to open it. V2 is the append CurrentSchema.swift
// describes, step for step:
//
//  - Every V1 model is copied below **verbatim**: same properties, same
//    attributes, same relationship rules and inverses, same initialisers,
//    same static keys. A `VersionedSchema` is a complete snapshot, so these
//    are V2's own types; nothing here names `BurlySchemaV1.Foo`, and V3
//    will copy these the same way rather than edit them. The field docs
//    stay on the V1 declarations in Models/, which these match exactly.
//  - `SessionTombstone` is the one addition, declared in its own file as
//    `extension BurlySchemaV2`.
//  - `BurlyMigrationPlan` takes V1 to V2 with one lightweight stage: a new
//    entity and no changed one, so there is nothing for a custom stage to
//    transform. `ShippedStoreMigrationTests` opens stores written by the
//    0.9.1 code through it.
//
// Once V2 ships, this file and Models/SessionTombstone.swift are frozen in
// turn.

import Foundation
import SwiftData
import BurlyCore

enum BurlySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// V1's list in V1's order, with the tombstone placed after the
    /// in-flight journal, beside the Session it records.
    static var models: [any PersistentModel.Type] {
        [
            Exercise.self,
            CatalogSeedState.self,
            Routine.self,
            RoutineItem.self,
            Session.self,
            ActiveSessionJournal.self,
            SessionTombstone.self,
            SessionItem.self,
            SetRecord.self,
            ExerciseLastPerformance.self,
            WatchSyncJournal.self
        ]
    }

    // MARK: - Copied verbatim from V1 (see Models/ for the field docs)

    @Model
    final class Exercise {
        @Attribute(.unique) var id: UUID
        var name: String
        var muscleGroups: [MuscleGroup]
        var origin: ExerciseOrigin
        var needsNaming: Bool
        var archivedAt: Date?

        // Resolve in `BurlySchemaV2`'s scope, so they name V2's own items.
        @Relationship(deleteRule: .deny, inverse: \RoutineItem.exercise)
        var routineItems: [RoutineItem] = []

        @Relationship(deleteRule: .deny, inverse: \SessionItem.exercise)
        var sessionItems: [SessionItem] = []

        init(
            id: UUID,
            name: String,
            muscleGroups: [MuscleGroup],
            origin: ExerciseOrigin,
            needsNaming: Bool,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.muscleGroups = muscleGroups
            self.origin = origin
            self.needsNaming = needsNaming
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class CatalogSeedState {
        static let exerciseCatalogKey = "exerciseCatalog"

        @Attribute(.unique) var key: String
        var version: Int

        init(key: String = exerciseCatalogKey, version: Int) {
            self.key = key
            self.version = version
        }
    }

    @Model
    final class Routine {
        @Attribute(.unique) var id: UUID
        var name: String
        var orderIndex: Int
        @Relationship(deleteRule: .cascade, inverse: \RoutineItem.routine)
        var items: [RoutineItem] = []
        var updatedAt: Date
        var archivedAt: Date?

        init(
            id: UUID,
            name: String,
            orderIndex: Int,
            updatedAt: Date,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.orderIndex = orderIndex
            self.updatedAt = updatedAt
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class RoutineItem {
        @Attribute(.unique) var id: UUID
        var exercise: Exercise?
        var order: Int
        var defaultSetCount: Int
        var restOverride: TimeInterval?
        var note: String?
        var routine: Routine?

        init(
            id: UUID,
            exercise: Exercise?,
            order: Int,
            defaultSetCount: Int,
            restOverride: TimeInterval?,
            note: String?
        ) {
            self.id = id
            self.exercise = exercise
            self.order = order
            self.defaultSetCount = defaultSetCount
            self.restOverride = restOverride
            self.note = note
        }
    }

    @Model
    final class Session {
        @Attribute(.unique) var id: UUID
        var routineID: UUID?
        var routineName: String?
        var startedAt: Date
        var endedAt: Date?
        var state: SessionState
        var revision: Int
        var healthKitWorkoutID: UUID?
        var origin: SessionOrigin
        @Relationship(deleteRule: .cascade, inverse: \SessionItem.session)
        var items: [SessionItem] = []
        var notes: String?

        init(
            id: UUID,
            routineID: UUID?,
            routineName: String?,
            startedAt: Date,
            endedAt: Date?,
            state: SessionState,
            revision: Int,
            healthKitWorkoutID: UUID?,
            origin: SessionOrigin,
            notes: String?
        ) {
            self.id = id
            self.routineID = routineID
            self.routineName = routineName
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.state = state
            self.revision = revision
            self.healthKitWorkoutID = healthKitWorkoutID
            self.origin = origin
            self.notes = notes
        }
    }

    @Model
    final class ActiveSessionJournal {
        @Attribute(.unique) var sessionID: UUID
        var payload: Data
        var updatedAt: Date

        init(sessionID: UUID, payload: Data, updatedAt: Date) {
            self.sessionID = sessionID
            self.payload = payload
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class SessionItem {
        @Attribute(.unique) var id: UUID
        var exercise: Exercise?
        var order: Int
        @Relationship(deleteRule: .cascade, inverse: \SetRecord.sessionItem)
        var sets: [SetRecord] = []
        var session: Session?

        init(id: UUID, exercise: Exercise?, order: Int) {
            self.id = id
            self.exercise = exercise
            self.order = order
        }
    }

    @Model
    final class SetRecord {
        @Attribute(.unique) var id: UUID
        var order: Int
        var weightKg: Double
        var reps: Int
        var isWarmup: Bool
        var completedAt: Date
        var sessionItem: SessionItem?

        init(
            id: UUID,
            order: Int,
            weight: Weight,
            reps: Int,
            isWarmup: Bool,
            completedAt: Date
        ) {
            self.id = id
            self.order = order
            self.weightKg = weight.kg
            self.reps = reps
            self.isWarmup = isWarmup
            self.completedAt = completedAt
        }
    }

    @Model
    final class ExerciseLastPerformance {
        @Attribute(.unique) var exerciseID: UUID
        var performedAt: Date
        var sets: [SetSnapshot]

        init(exerciseID: UUID, performedAt: Date, sets: [SetSnapshot]) {
            self.exerciseID = exerciseID
            self.performedAt = performedAt
            self.sets = sets
        }
    }

    @Model
    final class WatchSyncJournal {
        static let singletonKey = "watchSync"

        @Attribute(.unique) var key: String
        var payload: Data

        init(key: String = singletonKey, payload: Data) {
            self.key = key
            self.payload = payload
        }
    }
}
