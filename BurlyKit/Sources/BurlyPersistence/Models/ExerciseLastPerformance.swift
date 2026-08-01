// SPDX-License-Identifier: GPL-3.0-or-later
// ExerciseLastPerformance — spec §1 entity, **watch store content only**.
//
// The model class lives in BurlyPersistence with the rest of the schema, but
// only the watch ever writes rows: the phone derives digests from full
// history at push time (§1, §5 `digest` payload) and never stores them.
// Keeping the type in the single `BurlySchemaV1` means one versioned schema
// and one migration plan for both devices — the phone simply leaves the
// table empty. Module-internal (see Exercise.swift).

import Foundation
import SwiftData
import BurlyCore

@Model
final class ExerciseLastPerformance {
    /// One digest row per exercise, latest-wins (§5) — hence unique.
    /// Note this is a plain UUID, not a relationship: digests arrive from
    /// the phone and must not depend on the Exercise row existing yet.
    @Attribute(.unique) var exerciseID: UUID
    var performedAt: Date
    /// `SetSnapshot` is a `BurlyCore` Codable value struct; SwiftData
    /// persists Codable values natively (the spec's shorthand
    /// `@Attribute(.codable)` is not an actual `Attribute.Option`).
    var sets: [SetSnapshot]

    init(exerciseID: UUID, performedAt: Date, sets: [SetSnapshot]) {
        self.exerciseID = exerciseID
        self.performedAt = performedAt
        self.sets = sets
    }
}
