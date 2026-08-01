// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionItemData
//
// Value-type mirror of the SwiftData `SessionItem` entity (spec §1). See
// the module doc in BurlyCore.swift for the naming scheme this file
// follows.
//
// Imports Foundation for `UUID` (identity) only.
import Foundation

public struct SessionItemData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID

    /// Spec's `exercise: Exercise?` relationship, by UUID (see
    /// RoutineItemData's doc for why value types reference by identity).
    public var exerciseID: UUID?

    public var order: Int

    /// Spec's cascade-delete `sets: [SetRecord]` relationship, embedded.
    public var sets: [SetRecordData]

    public init(
        id: UUID = UUID(),
        exerciseID: UUID?,
        order: Int,
        sets: [SetRecordData] = []
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.order = order
        self.sets = sets
    }

    private enum CodingKeys: String, CodingKey {
        case id, exerciseID, order, sets
    }

    /// Custom decoder for §1 default symmetry: `sets` defaults to `[]`
    /// when absent, matching the memberwise initializer's default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        exerciseID = try container.decodeIfPresent(UUID.self, forKey: .exerciseID)
        order = try container.decode(Int.self, forKey: .order)
        sets = try container.decodeIfPresent([SetRecordData].self, forKey: .sets) ?? []
    }
}
