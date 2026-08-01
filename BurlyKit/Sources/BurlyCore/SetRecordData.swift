// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SetRecordData
//
// Value-type mirror of the SwiftData `SetRecord` entity (spec §1). See the
// module doc in BurlyCore.swift for the naming scheme this file follows,
// and Weight.swift for the canonical-kg construction guarantee this type
// relies on.
//
// Imports Foundation for `UUID` (identity) and `Date` (completedAt) only.
import Foundation

public struct SetRecordData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var order: Int

    /// Canonical stored unit (spec §1 acceptance #4): always kilograms.
    /// There is no public initializer that takes this as a raw `Double` —
    /// the only way to set it is through `Weight` (see `init` below), so a
    /// pounds figure can never land here without an explicit conversion.
    public private(set) var weightKg: Double

    public var reps: Int

    /// A tag, not a set type; excluded from PR/volume stats (spec §1).
    public var isWarmup: Bool
    public var completedAt: Date

    public init(
        id: UUID = UUID(),
        order: Int,
        weight: Weight,
        reps: Int,
        isWarmup: Bool = false,
        completedAt: Date
    ) {
        self.id = id
        self.order = order
        self.weightKg = weight.kg
        self.reps = reps
        self.isWarmup = isWarmup
        self.completedAt = completedAt
    }

    /// Reads the stored kg back out as a `Weight`.
    public var weight: Weight {
        Weight(kg: weightKg)
    }

    /// Replaces the weight, still only through `Weight` — mirrors the
    /// initializer's guarantee for post-construction edits (e.g. the
    /// phone's set-level editor, §6).
    public mutating func setWeight(_ weight: Weight) {
        weightKg = weight.kg
    }
}
