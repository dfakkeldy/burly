// SPDX-License-Identifier: GPL-3.0-or-later
// Routine — spec §1 entity. Module-internal and nested in BurlySchemaV1
// (see Exercise.swift and Schema/CurrentSchema.swift).

import Foundation
import SwiftData

extension BurlySchemaV1 {
    @Model
    final class Routine {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Manual user ordering of the routine list (§9 phone IA).
        var orderIndex: Int
        /// Spec §1: cascade delete, default `[]`. Storage order is undefined —
        /// `RoutineItem.order` is the ordering truth and mapping sorts by it.
        @Relationship(deleteRule: .cascade, inverse: \RoutineItem.routine)
        var items: [RoutineItem] = []
        var updatedAt: Date
        /// Spec §1: archive, don't delete, once sessions reference the routine.
        /// (Sessions hold `routineID`/`routineName` denormalized, so a routine
        /// that *is* hard-deleted still leaves history intact — §1 acceptance #2.)
        var archivedAt: Date?

        init(
            id: UUID,
            name: String,
            orderIndex: Int,
            updatedAt: Date,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.orderIndex = orderIndex
            self.updatedAt = updatedAt
            self.archivedAt = archivedAt
        }
    }
}
