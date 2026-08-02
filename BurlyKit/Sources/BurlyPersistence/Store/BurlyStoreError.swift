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
    /// `saveActiveSession` named a session that is stored but is **not**
    /// `.active` — it is `storedState` (m1-06 review round E).
    ///
    /// Finish is one-way. §4's recovery story is finish-or-discard, never
    /// un-finish, so there is no watch flow that writes to a session after
    /// it has left flight. Two things go wrong if this path is open:
    ///
    /// - **Resurrection.** A replicated `.logged` session created through
    ///   `createSession` at revision 42 could be flipped back to `.active`,
    ///   journalled, and resumed — carrying that borrowed revision, which
    ///   §5 then reads as "the phone edited this 41 times."
    /// - **Silent history edits.** Even without changing `state`, this path
    ///   reconciles the whole graph without incrementing `revision`. On a
    ///   finished session that is a set-level edit sync can never see. §6
    ///   edits are `applyPhoneEdit`, which does bump.
    ///
    /// Refusing on the *stored* state closes both, and makes the revision
    /// rule transitive: every `.active` row was born in this method's create
    /// branch at revision 1, so no `.active` row can hold any other value.
    case sessionNoLongerInFlight(sessionID: UUID, storedState: SessionState)
    // There is deliberately no `partialDigest` case (m1-06 review round F,
    // reverting round E). Round E made `applyDigest` refuse a payload that
    // acked a session whose sets named exercises the digest carried no
    // entry for. It looked like a §5 contradiction; it is a legitimate
    // payload. The phone may delete a session (§1 `deleteSession` is
    // public), and it keeps acked ids for ~30 days afterwards (§5), so the
    // sequence "watch finishes the only bench session → phone acks it →
    // user deletes it on the phone → the phone's next full-history digest
    // honestly carries no bench entry, and still acks" produces exactly
    // that shape. Round E threw on it, every time, until the ack aged out
    // of the 30-day window — after which no digest named the session at
    // all and it could never be pruned, violating §5's "zero delivered-and-
    // acked sessions remain on the watch" and leaving it to be
    // ghost-redelivered. A phone edit that removes a session's last sets
    // strands it the same way.
    //
    // The watch cannot distinguish "the phone deleted that history" from
    // "the payload is missing entries" — the evidence for the difference
    // only exists on the phone. So the anti-partial-digest invariant is the
    // digest *generator's* (M4, phone-side), stated as a contract on
    // `SessionDigestReceipt` and property-tested there. See
    // `BurlyStore.applyDigest`.
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
    // There is deliberately no `unboundedStatsQuery` case (m6-01 fix round
    // 2, review item 7 — reverting round 1's fix for this same finding).
    // Round 1 refused an all-nil `loggedSetSlices`/`loggedSessionDates`
    // call at runtime, but a runtime check on an *optional* `Date` cannot
    // stop a non-nil sentinel (`since: .distantPast`) from meaning the
    // same "unbounded" thing while satisfying "not nil" — and round 1's
    // own benchmark had quietly started relying on exactly that sentinel
    // to express "all-time". Round 2 closes the gap by API shape instead:
    // `loggedSetSlices` split into an exercise-bounded form (mandatory
    // `UUID`, no way to omit it) and an all-exercises form that takes a
    // validated `TrailingWindow` domain type instead of a `Date` a caller
    // could sentinel past; `loggedSessionDates`'s `since` became a plain
    // non-optional `Date`, with the genuinely-unbounded case promoted to
    // its own explicit, documented method, `allLoggedSessionDates()`. None
    // of `BurlyStore`'s stats-query methods can express an unbounded call
    // anymore, so there is no longer a runtime error to throw for one —
    // see `BurlyStore`'s stats-queries doc for the full reasoning.
}
