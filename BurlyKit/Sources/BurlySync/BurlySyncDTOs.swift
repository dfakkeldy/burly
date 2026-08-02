// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySync — wire DTOs
//
// These value types are the versioned JSON contract between the phone and
// watch. They deliberately do not expose SwiftData models or store APIs:
// converting a received DTO into a local model is an apply-layer concern.

import Foundation
import BurlyCore

/// The phone-to-watch whole-working-set replacement payload.
///
/// `version` is monotonically increasing for a given phone catalog. Its
/// interpretation (including how receivers discard stale snapshots) belongs
/// to the later sync state machine; this DTO only preserves the fact on the
/// wire. Both curated and custom exercises are present in `exercises`.
public struct BurlySnapshotPayloadDTO: Sendable, Equatable, Codable {
    /// A non-negative, monotonically increasing catalog/routine version.
    public let version: Int
    public let exercises: [BurlyExerciseDTO]
    public let routines: [BurlyRoutineDTO]

    public init(version: Int, exercises: [BurlyExerciseDTO], routines: [BurlyRoutineDTO]) {
        precondition(version >= 0, "Snapshot version must be non-negative.")
        self.version = version
        self.exercises = exercises
        self.routines = routines
    }

    private enum CodingKeys: String, CodingKey {
        case version, exercises, routines
    }

    /// Rejects a negative version at the untrusted JSON boundary. A
    /// programmatic negative version is a caller bug and is rejected by the
    /// initializer above; received JSON must fail normally instead of
    /// trapping.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Snapshot version must be non-negative."
            )
        }
        self.version = version
        exercises = try container.decode([BurlyExerciseDTO].self, forKey: .exercises)
        routines = try container.decode([BurlyRoutineDTO].self, forKey: .routines)
    }
}

/// A complete catalog exercise as represented on the sync wire.
public struct BurlyExerciseDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var muscleGroups: [MuscleGroup]
    public var origin: ExerciseOrigin
    public var needsNaming: Bool
    public var archivedAt: Date?

    public init(
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

/// A complete routine as represented on the sync wire.
public struct BurlyRoutineDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var orderIndex: Int
    public var items: [BurlyRoutineItemDTO]
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID,
        name: String,
        orderIndex: Int,
        items: [BurlyRoutineItemDTO],
        updatedAt: Date,
        archivedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.items = items
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

/// One exercise placement in a routine on the sync wire.
public struct BurlyRoutineItemDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var exerciseID: UUID?
    public var order: Int
    public var defaultSetCount: Int
    public var restOverride: TimeInterval?
    public var note: String?

    public init(
        id: UUID,
        exerciseID: UUID?,
        order: Int,
        defaultSetCount: Int,
        restOverride: TimeInterval?,
        note: String?
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.order = order
        self.defaultSetCount = defaultSetCount
        self.restOverride = restOverride
        self.note = note
    }
}

/// The watch-to-phone payload for one complete session.
///
/// `needsNamingExercises` contains a minimal identity DTO for each
/// watch-created placeholder referenced by `session`. The fixed facts of a
/// placeholder (custom origin, no tags, and "needs naming") are not copied
/// as mutable wire fields; later apply code reconstructs them from this
/// identity without guessing at a name.
public struct BurlySessionPayloadDTO: Sendable, Equatable, Codable {
    public let session: BurlySessionDTO
    public let needsNamingExercises: [BurlyNeedsNamingExerciseDTO]

    public init(session: BurlySessionDTO, needsNamingExercises: [BurlyNeedsNamingExerciseDTO]) {
        self.session = session
        self.needsNamingExercises = needsNamingExercises
    }
}

/// A complete session, including its HealthKit link and revision.
public struct BurlySessionDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var routineID: UUID?
    public var routineName: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var state: SessionState
    public var revision: Int
    public var healthKitWorkoutID: UUID?
    public var origin: SessionOrigin
    public var items: [BurlySessionItemDTO]
    public var notes: String?

    public init(
        id: UUID,
        routineID: UUID?,
        routineName: String?,
        startedAt: Date,
        endedAt: Date?,
        state: SessionState,
        revision: Int,
        healthKitWorkoutID: UUID?,
        origin: SessionOrigin,
        items: [BurlySessionItemDTO],
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
        self.items = items
        self.notes = notes
    }
}

/// One exercise row in a complete session.
public struct BurlySessionItemDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var exerciseID: UUID?
    public var order: Int
    public var sets: [BurlySetDTO]

    public init(id: UUID, exerciseID: UUID?, order: Int, sets: [BurlySetDTO]) {
        self.id = id
        self.exerciseID = exerciseID
        self.order = order
        self.sets = sets
    }
}

/// One logged set in a session. `weight` routes untrusted JSON through
/// `Weight`'s finite, non-negative kilogram validation boundary.
public struct BurlySetDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var order: Int
    public var weight: Weight
    public var reps: Int
    public var isWarmup: Bool
    public var completedAt: Date

    public init(
        id: UUID,
        order: Int,
        weight: Weight,
        reps: Int,
        isWarmup: Bool,
        completedAt: Date
    ) {
        self.id = id
        self.order = order
        self.weight = weight
        self.reps = reps
        self.isWarmup = isWarmup
        self.completedAt = completedAt
    }
}

/// The deliberately minimal identity carried beside a session for a
/// watch-created placeholder exercise that still needs a phone-side name.
public struct BurlyNeedsNamingExerciseDTO: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// The phone-to-watch latest-wins digest payload.
///
/// `lastPerformance` intentionally reuses `ExerciseLastPerformanceData`.
/// Its complete-history generator contract is documented at that type's
/// existing sync seam (`SessionDigestReceipt`); this DTO does not duplicate
/// or weaken that contract.
public struct BurlyDigestPayloadDTO: Sendable, Equatable, Codable {
    /// The snapshot version from which this latest-wins digest was derived.
    public let snapshotVersion: Int
    public let lastPerformance: [ExerciseLastPerformanceData]
    public let ackedSessionIDs: [UUID]

    public init(
        snapshotVersion: Int,
        lastPerformance: [ExerciseLastPerformanceData],
        ackedSessionIDs: [UUID]
    ) {
        precondition(snapshotVersion >= 0, "Snapshot version must be non-negative.")
        self.snapshotVersion = snapshotVersion
        self.lastPerformance = lastPerformance
        self.ackedSessionIDs = ackedSessionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotVersion, lastPerformance, ackedSessionIDs
    }

    /// Fails closed for a negative snapshot version received over the wire.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshotVersion = try container.decode(Int.self, forKey: .snapshotVersion)
        guard snapshotVersion >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotVersion,
                in: container,
                debugDescription: "Snapshot version must be non-negative."
            )
        }
        self.snapshotVersion = snapshotVersion
        lastPerformance = try container.decode([ExerciseLastPerformanceData].self, forKey: .lastPerformance)
        ackedSessionIDs = try container.decode([UUID].self, forKey: .ackedSessionIDs)
    }
}
