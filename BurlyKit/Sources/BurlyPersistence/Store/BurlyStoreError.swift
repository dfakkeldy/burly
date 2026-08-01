// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum BurlyStoreError: Error, Equatable {
    /// A create call named an id that is already stored. Creates are strict
    /// rather than upserts on purpose: SwiftData's `.unique` attribute
    /// silently *merges* a duplicate insert, which would quietly overwrite
    /// history. Sync's upsert-by-UUID rule (§5) belongs in explicit upsert
    /// methods, not hidden inside `create`.
    case duplicateID(UUID)
    /// The referenced record does not exist.
    case notFound(UUID)
    /// A routine or session item referenced an exercise that isn't stored.
    /// (The spec allows a *nil* exercise reference; it does not allow a
    /// dangling one.)
    case missingExercise(UUID)
    /// The call is only valid against a watch-kind store. Today this guards
    /// `upsertLastPerformance`: the phone derives digests from full history
    /// at push time and never stores `ExerciseLastPerformance` rows (§1).
    /// A phone-kind store — or a store whose kind cannot be determined —
    /// refuses the write rather than silently accumulating rows it should
    /// never have.
    case operationRequiresWatchStore
}
