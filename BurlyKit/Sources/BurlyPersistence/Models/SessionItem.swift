// SPDX-License-Identifier: GPL-3.0-or-later
// SessionItem — spec §1 entity. Module-internal and nested in BurlySchemaV1
// (see Exercise.swift and Schema/CurrentSchema.swift).

import Foundation
import SwiftData

extension BurlySchemaV1 {
    @Model
    final class SessionItem {
        @Attribute(.unique) var id: UUID
        /// Bare on purpose: the pair's `@Relationship` macro lives on
        /// `Exercise.sessionItems` (`.deny`), never on both sides.
        var exercise: Exercise?
        var order: Int
        /// Spec §1: cascade delete, default `[]`. Ordering truth is
        /// `SetRecord.order`; mapping sorts by it.
        @Relationship(deleteRule: .cascade, inverse: \SetRecord.sessionItem)
        var sets: [SetRecord] = []

        /// Inverse of `Session.items` (declared there, with `.cascade`).
        var session: Session?

        init(id: UUID, exercise: Exercise?, order: Int) {
            self.id = id
            self.exercise = exercise
            self.order = order
        }
    }
}
