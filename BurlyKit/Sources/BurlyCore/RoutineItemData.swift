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
}
