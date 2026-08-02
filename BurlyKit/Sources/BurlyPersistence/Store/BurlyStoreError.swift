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
    /// `applyDigest` and the watch working-set members: the phone derives
    /// digests from full history at push time and never stores
    /// `ExerciseLastPerformance` rows (§1). A phone-kind store — or a store
    /// whose kind cannot be determined — refuses the write rather than
    /// silently accumulating rows it should never have.
    case operationRequiresWatchStore
    /// A write path other than `saveActiveSession` was handed a session in
    /// `.active` state (m1-06 review round D).
    ///
    /// An `.active` row is only half of an in-flight session: the other
    /// half is its `ActiveSessionJournal`, and §2 Resume is only correct
    /// while the two exist together. `saveActiveSession` is the one method
    /// that writes both in one save, so it is the one method allowed to
    /// produce the state — `createSession` cannot mint an active row with
    /// no journal, and `applyPhoneEdit` cannot resurrect a finished session
    /// into one.
    case activeSessionRequiresSaveActiveSession(sessionID: UUID)
    /// `saveActiveSession` was asked to bring a second session into flight
    /// while `existingID` is still `.active` (m1-06 review round D).
    ///
    /// §2 performs one workout at a time, and Resume promises *the* session
    /// to offer, not a choice. The store enforces that rather than picking
    /// a winner: finish or discard the session already in flight first. See
    /// `BurlyStore.saveActiveSession(_:)`.
    case activeSessionAlreadyInFlight(existingID: UUID, incomingID: UUID)
    /// `saveActiveSession` was handed a malformed `ActiveSession`. The
    /// strings are `ActiveSession.invariantViolations()` verbatim (dense
    /// item/set order, plan bijection, plan floor); the store refuses the
    /// whole transaction rather than persisting a graph the §2 engine
    /// would not recognise on the way back out.
    case invalidActiveSession(sessionID: UUID, violations: [String])
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
