// SPDX-License-Identifier: GPL-3.0-or-later
// The migration spike's throwaway v2 — **test target only, never shipped.**
//
// ## What it is for
//
// m1-06 review, finding M3: §1 promises that "v2 is an append, not a
// retrofit", and until this round that promise was untested and in fact
// false — the models were top-level classes that v2 would have had to edit
// in place. The models are now nested in `BurlySchemaV1`
// (Sources/BurlyPersistence/Schema/CurrentSchema.swift), and this file is
// the proof that the resulting ladder actually carries data: it performs
// the real v2 procedure end to end against a store file on disk.
//
// ## Why it lives in the test target
//
// The shipping `BurlyMigrationPlan` must keep declaring exactly
// `[BurlySchemaV1]` with no stages — a real v2 in Sources/ would change
// what every user's store migrates to. SwiftData imposes no obstacle to
// declaring a `VersionedSchema` and a `SchemaMigrationPlan` outside the
// module that owns v1: schemas are matched by *entity* name and shape, not
// by Swift type identity or module, so a plan assembled here migrates a
// store that BurlyPersistence wrote. `MigrationPlanTests` asserts the
// shipping plan is untouched by any of this.
//
// ## What v2 changes
//
// One additive optional column: `SetRecord.rpe`. Deliberately the smallest
// possible change, because the spike is testing the *ladder*, not a
// transformation. Everything else is copied from v1 verbatim.
//
// And copied is the point: a `VersionedSchema` is a complete snapshot, not
// a diff, so v2 re-declares all nine models rather than reaching back for
// `BurlySchemaV1.Exercise`. Reaching back would reintroduce exactly the
// defect this round fixes, one version later — v3 editing `Exercise` would
// silently rewrite what v2 means. The verbatim copying below is what a real
// `Schema/BurlySchemaV2.swift` would look like.

import Foundation
import Synchronization
import SwiftData
import BurlyCore
@testable import BurlyPersistence

enum MigrationSpikeSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Exercise.self,
            CatalogSeedState.self,
            Routine.self,
            RoutineItem.self,
            Session.self,
            ActiveSessionJournal.self,
            SessionItem.self,
            SetRecord.self,
            ExerciseLastPerformance.self
        ]
    }

    // MARK: - Unchanged from v1 (copied verbatim)

    @Model
    final class Exercise {
        @Attribute(.unique) var id: UUID
        var name: String
        var muscleGroups: [MuscleGroup]
        var origin: ExerciseOrigin
        var needsNaming: Bool
        var archivedAt: Date?

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
        @Attribute(.unique) var key: String
        var version: Int

        init(key: String, version: Int) {
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

    // MARK: - The one v2 change

    /// v1's `SetRecord` plus `rpe`. Optional with no default, which is the
    /// cheapest kind of schema change there is: the stage adds a nullable
    /// column and every existing row reads back `nil`.
    @Model
    final class SetRecord {
        @Attribute(.unique) var id: UUID
        var order: Int
        var weightKg: Double
        var reps: Int
        var isWarmup: Bool
        var completedAt: Date

        /// New in v2.
        var rpe: Double?

        var sessionItem: SessionItem?

        init(
            id: UUID,
            order: Int,
            weight: Weight,
            reps: Int,
            isWarmup: Bool,
            completedAt: Date,
            rpe: Double? = nil
        ) {
            self.id = id
            self.order = order
            self.weightKg = weight.kg
            self.reps = reps
            self.isWarmup = isWarmup
            self.completedAt = completedAt
            self.rpe = rpe
        }
    }
}

/// What the v1 → v2 stage saw while it ran. Without this the spike could
/// only show that a v2 container *opened* a v1 file — which SwiftData will
/// also do by inferring a lightweight migration, with or without a plan.
/// Recording from inside the stage is what distinguishes "the ladder ran"
/// from "SwiftData coped".
struct SpikeMigrationTrace: Sendable, Equatable {
    /// Set by `willMigrate`, which by SwiftData's contract can see only the
    /// *old* shape — so a non-nil value here is proof v1 is still a
    /// nameable, fetchable schema at migration time.
    var setRecordsSeenAsV1: Int?
    /// Set by `didMigrate`, which can see only the *new* shape.
    var setRecordsSeenAsV2: Int?
}

let spikeMigrationTrace = Mutex(SpikeMigrationTrace())

/// The ladder as it would look after step 2 of the v2 procedure: v1 first,
/// v2 appended, one stage between them. Nothing is reordered or removed.
///
/// The stage is `.custom` purely so it can record; a real additive v2 would
/// use `.lightweight` and the column change would be identical. The
/// closures deliberately mutate nothing, so migrated rows still read back
/// `rpe == nil`.
enum MigrationSpikePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BurlySchemaV1.self, MigrationSpikeSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: BurlySchemaV1.self,
        toVersion: MigrationSpikeSchemaV2.self,
        willMigrate: { context in
            let count = try context.fetchCount(FetchDescriptor<BurlySchemaV1.SetRecord>())
            spikeMigrationTrace.withLock { $0.setRecordsSeenAsV1 = count }
        },
        didMigrate: { context in
            let count = try context.fetchCount(
                FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()
            )
            spikeMigrationTrace.withLock { $0.setRecordsSeenAsV2 = count }
        }
    )
}

/// Opens an existing store file at v2, through the spike ladder — step 3 of
/// the v2 procedure. Mirrors `BurlyContainer.make` exactly (same
/// configuration name, same `ModelContainer(for:migrationPlan:)` call), so
/// what the test exercises is the migration, not a different way of opening
/// a store.
func openThroughSpikeLadder(_ kind: BurlyStoreKind, at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: MigrationSpikeSchemaV2.self)
    return try ModelContainer(
        for: schema,
        migrationPlan: MigrationSpikePlan.self,
        configurations: ModelConfiguration(kind.storeName, schema: schema, url: url)
    )
}
