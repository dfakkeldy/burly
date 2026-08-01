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

    private enum CodingKeys: String, CodingKey {
        case id, order, weightKg, reps, isWarmup, completedAt
    }

    /// Custom decoder, for two reasons `Codable` synthesis can't cover:
    ///
    /// 1. **Closing the Decodable hole**: the memberwise `init` only ever
    ///    accepts weight through `Weight`, but synthesized `Decodable`
    ///    would decode `weightKg` as a bare, unvalidated `Double` — the one
    ///    path that could smuggle a negative, NaN, or infinite value past
    ///    the type's guarantee. Routing it through
    ///    `Weight(validatingKg:)` closes that hole.
    /// 2. **§1 default symmetry**: `isWarmup` defaults to `false` when
    ///    absent from the payload, matching the memberwise initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)

        let rawWeightKg = try container.decode(Double.self, forKey: .weightKg)
        do {
            weightKg = try Weight(validatingKg: rawWeightKg).kg
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .weightKg,
                in: container,
                debugDescription: "weightKg must be a finite, non-negative number (decoded \(rawWeightKg))."
            )
        }

        reps = try container.decode(Int.self, forKey: .reps)
        isWarmup = try container.decodeIfPresent(Bool.self, forKey: .isWarmup) ?? false
        completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}
