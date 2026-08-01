// SPDX-License-Identifier: GPL-3.0-or-later
// RoutineItem — spec §1 entity. Module-internal and nested in BurlySchemaV1
// (see Exercise.swift and Schema/CurrentSchema.swift).

import Foundation
import SwiftData

extension BurlySchemaV1 {
    @Model
    final class RoutineItem {
        @Attribute(.unique) var id: UUID
        /// Bare on purpose: the pair's `@Relationship` macro lives on
        /// `Exercise.routineItems` (`.deny`), never on both sides.
        var exercise: Exercise?
        var order: Int
        var defaultSetCount: Int
        /// nil → routine/global rest default (§3 resolution order).
        var restOverride: TimeInterval?
        var note: String?

        /// Inverse of `Routine.items` (declared there, with `.cascade`).
        var routine: Routine?

        init(
            id: UUID,
            exercise: Exercise?,
            order: Int,
            defaultSetCount: Int,
            restOverride: TimeInterval?,
            note: String?
        ) {
            self.id = id
            self.exercise = exercise
            self.order = order
            self.defaultSetCount = defaultSetCount
            self.restOverride = restOverride
            self.note = note
        }
    }
}
