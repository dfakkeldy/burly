// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — RoutineData
//
// Value-type mirror of the SwiftData `Routine` entity (spec §1). See the
// module doc in BurlyCore.swift for the naming scheme this file follows.
//
// Imports Foundation for `UUID` (identity) and `Date` (updatedAt,
// archivedAt) only.
import Foundation

public struct RoutineData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String

    /// Manual user ordering among routines (spec §1).
    public var orderIndex: Int

    /// Spec's cascade-delete `items: [RoutineItem]` relationship, as an
    /// embedded value array (there is no separate object graph at this
    /// layer to cascade through — the mapping to SwiftData's real cascade
    /// is BurlyPersistence's job).
    public var items: [RoutineItemData]

    public var updatedAt: Date

    /// Archived, never deleted — sessions carry a routine reference for
    /// provenance (spec §1).
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        orderIndex: Int,
        items: [RoutineItemData] = [],
        updatedAt: Date,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.items = items
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}
