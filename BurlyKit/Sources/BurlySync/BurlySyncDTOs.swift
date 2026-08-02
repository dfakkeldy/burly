// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySync — wire payloads
//
// The versioned envelope and its three payload wrappers are the only sync
// DTOs. Their contents deliberately reuse BurlyCore's framework-free value
// types, which are themselves the cross-module and cross-device data contract.

import Foundation
import BurlyCore

/// The phone-to-watch whole-working-set replacement payload.
///
/// `version` is monotonically increasing for a given phone catalog. Its
/// interpretation (including how receivers discard stale snapshots) belongs
/// to the later sync state machine; this payload only preserves the fact on
/// the wire. Both curated and custom exercises are present in `exercises`.
public struct BurlySnapshotPayloadDTO: Sendable, Equatable, Codable {
    /// A non-negative, monotonically increasing catalog/routine version.
    public let version: Int
    public let exercises: [ExerciseData]
    public let routines: [RoutineData]

    public init(version: Int, exercises: [ExerciseData], routines: [RoutineData]) {
        precondition(version >= 0, "Snapshot version must be non-negative.")
        self.version = version
        self.exercises = exercises
        self.routines = routines
    }

    private enum CodingKeys: String, CodingKey {
        case version, exercises, routines
    }

    /// Wire payloads require fields that the domain `*Data` decoders default,
    /// so a truncated sync message never silently changes its meaning.
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

        try validateElements(
            in: container,
            forKey: .exercises,
            as: StrictExerciseData.self
        )
        try validateElements(
            in: container,
            forKey: .routines,
            as: StrictRoutineData.self
        )

        self.version = version
        exercises = try container.decode([ExerciseData].self, forKey: .exercises)
        routines = try container.decode([RoutineData].self, forKey: .routines)
    }
}

/// The watch-to-phone payload for one complete session.
///
/// `needsNamingExercises` embeds the watch-created placeholders referenced by
/// `session`. `ExerciseData` fully expresses them (`.custom` plus
/// `needsNaming`), so no parallel placeholder DTO is needed.
public struct BurlySessionPayloadDTO: Sendable, Equatable, Codable {
    public let session: SessionData
    public let needsNamingExercises: [ExerciseData]

    public init(session: SessionData, needsNamingExercises: [ExerciseData]) {
        self.session = session
        self.needsNamingExercises = needsNamingExercises
    }

    private enum CodingKeys: String, CodingKey {
        case session, needsNamingExercises
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try StrictSessionData(from: container.superDecoder(forKey: .session))
        try validateElements(
            in: container,
            forKey: .needsNamingExercises,
            as: StrictExerciseData.self
        )

        session = try container.decode(SessionData.self, forKey: .session)
        needsNamingExercises = try container.decode([ExerciseData].self, forKey: .needsNamingExercises)
    }
}

/// The phone-to-watch latest-wins digest payload.
///
/// `lastPerformance` intentionally reuses `ExerciseLastPerformanceData`.
/// Its complete-history generator contract is documented at that type's
/// existing sync seam (`SessionDigestReceipt`); this payload does not duplicate
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

private extension KeyedDecodingContainer {
    func require(_ key: Key) throws {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Required sync wire field \(key.stringValue) is missing."
                )
            )
        }
    }
}

private func validateElements<Key: CodingKey, Element: Decodable>(
    in container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    as _: Element.Type
) throws {
    var elements = try container.nestedUnkeyedContainer(forKey: key)
    while !elements.isAtEnd {
        _ = try elements.decode(Element.self)
    }
}

/// Validates fields whose corresponding `ExerciseData` decoder defaults for
/// local/domain compatibility. It stores no duplicate wire model.
private struct StrictExerciseData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case needsNaming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.needsNaming)
    }
}

/// Validates `RoutineData`'s defaulted nested fields without creating a second
/// routine representation for the sync contract.
private struct StrictRoutineData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try validateElements(in: container, forKey: .items, as: StrictRoutineItemData.self)
    }
}

private struct StrictRoutineItemData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case defaultSetCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.defaultSetCount)
    }
}

private struct StrictSessionData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case state, revision, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.state)
        try container.require(.revision)
        try validateElements(in: container, forKey: .items, as: StrictSessionItemData.self)
    }
}

private struct StrictSessionItemData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try validateElements(in: container, forKey: .sets, as: StrictSetRecordData.self)
    }
}

private struct StrictSetRecordData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case isWarmup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.isWarmup)
    }
}
