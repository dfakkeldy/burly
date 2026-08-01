// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — RoutineItemData
//
// Value-type mirror of the SwiftData `RoutineItem` entity (spec §1). See
// the module doc in BurlyCore.swift for the naming scheme this file
// follows.
//
// Imports Foundation for `UUID` (identity) and `TimeInterval` (a
// Foundation typealias for `Double`, used for restOverride) only.
import Foundation

public struct RoutineItemData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID

    /// Spec's `exercise: Exercise?` relationship, by UUID: BurlyCore value
    /// types reference other entities by identity, never by SwiftData
    /// object graph (architecture doc — "cross-device references are by
    /// UUID, never by SwiftData object identity"). Optional to mirror the
    /// spec's optional relationship exactly.
    public var exerciseID: UUID?

    public var order: Int
    public var defaultSetCount: Int

    /// `nil` falls back to the routine/global default (§3).
    public var restOverride: TimeInterval?
    public var note: String?

    public init(
        id: UUID = UUID(),
        exerciseID: UUID?,
        order: Int,
        defaultSetCount: Int = 3,
        restOverride: TimeInterval? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.order = order
        self.defaultSetCount = defaultSetCount
        self.restOverride = restOverride
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, exerciseID, order, defaultSetCount, restOverride, note
    }

    /// Custom decoder for §1 default symmetry: `defaultSetCount` defaults
    /// to 3 when absent, matching the memberwise initializer's default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        exerciseID = try container.decodeIfPresent(UUID.self, forKey: .exerciseID)
        order = try container.decode(Int.self, forKey: .order)
        defaultSetCount = try container.decodeIfPresent(Int.self, forKey: .defaultSetCount) ?? 3
        restOverride = try container.decodeIfPresent(TimeInterval.self, forKey: .restOverride)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}
