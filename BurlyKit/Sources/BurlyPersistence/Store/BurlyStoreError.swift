// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import BurlyCore

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
    /// `saveActiveSession` was handed a malformed `ActiveSession`. The
    /// strings are `ActiveSession.invariantViolations()` verbatim (dense
    /// item/set order, plan bijection, plan floor); the store refuses the
    /// whole transaction rather than persisting a graph the §2 engine
    /// would not recognise on the way back out.
    case invalidActiveSession(sessionID: UUID, violations: [String])
    /// A §5 digest entry carried a `weightKg` that is negative, NaN, or
    /// infinite. Rejecting the entry rejects the *whole* digest: a digest
    /// is one latest-wins payload, and applying the half of it that
    /// happened to validate would leave the watch's ghost rows describing
    /// a state the phone never sent.
    case invalidLastPerformance(exerciseID: UUID)
    /// An `ActiveSessionJournal` row exists but its payload will not
    /// decode. Fails closed rather than resuming a session with invented
    /// scaffolding: §2's Resume screen showing the wrong set slots is
    /// worse than Resume reporting an error.
    case unreadableActiveSessionJournal(sessionID: UUID)
    /// A stored `SetRecord.weightKg` column failed `Weight`'s finite/
    /// non-negative invariant on read-back (m1-06 review, finding M5).
    /// The store's own write paths cannot produce this — `Weight`'s
    /// non-throwing initializers trap on an invalid value before it ever
    /// reaches a column — so seeing this means the row was written
    /// out-of-band (direct SQL, a bad migration, disk corruption). Fails
    /// closed with the offending record's id and the underlying validation
    /// failure rather than handing a poisoned `Weight` back into equality,
    /// sorting, volume, PR, or chart math.
    case corruptedWeight(id: UUID, underlying: WeightValidationError)
}
