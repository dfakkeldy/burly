// SPDX-License-Identifier: GPL-3.0-or-later
// SetRecord — spec §1 entity. Module-internal and nested in BurlySchemaV1
// (see Exercise.swift and Schema/CurrentSchema.swift).

import Foundation
import SwiftData
import BurlyCore

extension BurlySchemaV1 {
    @Model
    final class SetRecord {
        @Attribute(.unique) var id: UUID
        var order: Int
        /// **Canonical unit is kg, always** (§1, §1 acceptance #4). There is no
        /// `weightLb` column and no API path that writes one: the store only
        /// accepts `BurlyCore.Weight`, which normalises to kg on construction.
        /// 0 kg is the bodyweight convention (§8).
        var weightKg: Double
        var reps: Int
        /// A tag, not a set type — excluded from PR/volume stats (§7).
        var isWarmup: Bool
        var completedAt: Date

        /// Inverse of `SessionItem.sets` (declared there, with `.cascade`).
        var sessionItem: SessionItem?

        init(
            id: UUID,
            order: Int,
            weight: Weight,
            reps: Int,
            isWarmup: Bool,
            completedAt: Date
        ) {
            self.id = id
            self.order = order
            self.weightKg = weight.kg
            self.reps = reps
            self.isWarmup = isWarmup
            self.completedAt = completedAt
        }
    }
}
