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
///
/// ## Phone settings the watch follows (schema 2)
///
/// `displayUnit` and `restDefault` are the phone's §9 Settings rows that the
/// watch must honour: weights render in the phone's unit, and §3's rest
/// ladder ends at the phone's global default instead of a hardcoded 90 s.
/// They ride the snapshot rather than the digest because the snapshot is
/// already "everything the watch needs to start a workout", replaced as a
/// whole and versioned, so a settings change is one more reason to push it.
///
/// They are the one deliberate exception to "wire payloads require fields
/// the domain decoders default". A schema-1 sender predates them and meant
/// exactly kg and the §3 90 s default, so a schema-1 body decodes to those.
/// Schema 2 requires both keys; `BurlySyncEnvelope` enforces that per
/// version, so a truncated schema-2 snapshot is still malformed.
///
/// `restDefault` is clamped onto §3's 15 s–5 min, 15 s grid rather than
/// rejected: an off-grid value has an obvious nearest answer, and refusing
/// the whole snapshot over it would also refuse every routine in it.
public struct BurlySnapshotPayloadDTO: Sendable, Equatable, Codable {
    /// A non-negative, monotonically increasing catalog/routine version.
    public let version: Int
    public let exercises: [ExerciseData]
    public let routines: [RoutineData]
    /// The phone's display unit. Storage stays canonical kg on both sides.
    public let displayUnit: WeightUnit
    /// The phone's §3 global rest default, always on the §3 grid.
    public let restDefault: TimeInterval

    public init(
        version: Int,
        exercises: [ExerciseData],
        routines: [RoutineData],
        displayUnit: WeightUnit = .kilograms,
        restDefault: TimeInterval = RestDuration.globalDefault
    ) {
        precondition(version >= 0, "Snapshot version must be non-negative.")
        self.version = version
        self.exercises = exercises
        self.routines = routines
        self.displayUnit = displayUnit
        self.restDefault = RestDuration.clamped(restDefault)
    }

    private enum CodingKeys: String, CodingKey {
        case version, exercises, routines, displayUnit, restDefault
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
        // Presence is the envelope's per-schema decision (see the type doc).
        displayUnit = try container.decodeIfPresent(WeightUnit.self, forKey: .displayUnit) ?? .kilograms
        restDefault = RestDuration.clamped(
            try container.decodeIfPresent(TimeInterval.self, forKey: .restDefault) ?? RestDuration.globalDefault
        )
    }
}

/// Schema 2's addition to a snapshot body: both phone settings must be
/// present. Validates only; `BurlySnapshotPayloadDTO` does the decoding.
struct StrictSnapshotSettings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case displayUnit, restDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.displayUnit)
        try container.require(.restDefault)
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

    /// Fails closed for a negative snapshot version received over the
    /// wire, and — like the other two payloads — requires the fields the
    /// domain decoders default (m4-01 review 2 closed the gap here: the
    /// digest was the one payload without a strict pass, so a truncated
    /// `SetSnapshot` could silently decode as a work set).
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

        try validateElements(
            in: container,
            forKey: .lastPerformance,
            as: StrictExerciseLastPerformanceData.self
        )

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

/// Validates the digest payload's one defaulted nested field:
/// `ExerciseLastPerformanceData` itself decodes synthesized (every field
/// required), but its embedded `SetSnapshot`s default `isWarmup` — a
/// domain-side convenience the wire must not inherit (m4-01 review 2).
private struct StrictExerciseLastPerformanceData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try validateElements(in: container, forKey: .sets, as: StrictSetSnapshot.self)
    }
}

private struct StrictSetSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case isWarmup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try container.require(.isWarmup)
    }
}
