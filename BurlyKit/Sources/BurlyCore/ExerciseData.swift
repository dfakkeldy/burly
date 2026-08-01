// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ExerciseData
//
// Value-type mirror of the SwiftData `Exercise` entity (spec §1). See the
// module doc in BurlyCore.swift for the naming scheme this file follows.
//
// Imports Foundation for `UUID` (identity) and `Date` (archivedAt) only —
// both required because the spec's entities are UUID-keyed and
// timestamped.
import Foundation

public struct ExerciseData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String

    /// Multi-tag muscle groups (e.g. bench press → chest, triceps,
    /// shoulders); drives the muscle-split stat (§7, fractional
    /// attribution). Order is not meaningful.
    public var muscleGroups: [MuscleGroup]

    public var origin: ExerciseOrigin

    /// True only for watch-created placeholders ("Custom — name on
    /// phone", §2/§6) awaiting a real name from the phone.
    public var needsNaming: Bool

    /// Archived, never deleted, once any SetRecord references it (history
    /// integrity, §1). `nil` means active/unarchived.
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        muscleGroups: [MuscleGroup],
        origin: ExerciseOrigin,
        needsNaming: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.muscleGroups = muscleGroups
        self.origin = origin
        self.needsNaming = needsNaming
        self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, muscleGroups, origin, needsNaming, archivedAt
    }

    /// Custom decoder for §1 default symmetry (m1-06 review, finding m1):
    /// synthesized `Decodable` would fail a payload that omits
    /// `needsNaming` instead of defaulting it to `false` like the
    /// memberwise initializer does — mirrors `RoutineData`'s decoder for
    /// `items`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        muscleGroups = try container.decode([MuscleGroup].self, forKey: .muscleGroups)
        origin = try container.decode(ExerciseOrigin.self, forKey: .origin)
        needsNaming = try container.decodeIfPresent(Bool.self, forKey: .needsNaming) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}
