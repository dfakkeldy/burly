// SPDX-License-Identifier: GPL-3.0-or-later
// ActiveSessionJournal — the half of an in-flight session §1 has no entity
// for, plus the bounded index §2 Resume looks through.
//
// ## Why this exists at all
//
// `ActiveSession` (BurlyCore) is a `SessionData` plus two things that are
// scaffolding rather than history: `plans` (the "of 3" in "Set 2 of 3",
// the skip flag, the per-item rest override) and `restTimer`. §1 is frozen
// and deliberately stores neither — a session that ended with 2 of 3
// planned sets logged *is* two sets. But §3 requires the timer to be "part
// of the active session record" so it survives crash/resume, and §2's
// Resume screen has to come back with the same set slots the lifter was
// looking at. So the scaffolding has to be durable somewhere, and it has
// to become durable in the *same transaction* as the session graph it
// describes: a set row and a plan blob written by two separate saves can
// disagree across a crash, which is exactly the split-brain the m1-06
// review named as the M1 blocker.
//
// One row per in-flight session, and — since the m1-06 round-D work — at
// most one row in the store at a time (`saveActiveSession` refuses a second
// session in flight).
//
// **Written** only by `SwiftDataStore.saveActiveSession(_:)`: that is the
// single transaction which puts a session into `.active` and journals its
// scaffolding together. **Retired** by whichever path takes the session out
// of `.active` or out of the store, each in the same save as the change
// that caused it (m1-06 review round E — this comment used to claim
// `saveActiveSession` did both):
//
// - `saveActiveSession` on Finish — the `.logged`/`endedAt` write;
// - `applyPhoneEdit` when a §6 edit moves the session out of `.active`;
// - `deleteSession` — Discard, which has no session left to point at;
// - `applyDigest`'s prune, defensively, for an acked session that somehow
//   still carries one;
// - `resumableActiveSession`, which deletes rows naming a finished or
//   absent session as it scans past them.
//
// The invariant all five maintain is the one Resume depends on: a journal
// row exists if and only if its session is `.active`.
//
// ## Why it is also the Resume index
//
// `ActiveSessionJournal` rows exist while a session is `.active` and are
// deleted on Finish, so "is there something to resume?" is a
// `fetchLimit = 1` question against a table that holds at most one row —
// not a full `Session` scan filtered in Swift. SwiftData cannot answer it
// directly: `#Predicate { $0.state == .active }` fails at runtime with
// "Captured/constant values of type 'SessionState' are not supported"
// (measured; pinned by ActiveSessionTransactionTests). This table is the
// index that makes the bounded query possible.
//
// ## Registering it in V1
//
// Same reasoning as `CatalogSeedState`: BurlySchemaV1 has not shipped, so
// adding this model to V1 is an additive completion of the initial schema,
// not a migration of user data. It is module-internal bookkeeping, not a
// §1 domain entity, and nothing about it crosses the sync wire. Nested in
// `BurlySchemaV1` like every other model — see Schema/CurrentSchema.swift.

import Foundation
import SwiftData
import BurlyCore

extension BurlySchemaV1 {
    @Model
    final class ActiveSessionJournal {
        /// The `Session` this journal belongs to. Unique: a session has one
        /// in-flight record or none.
        @Attribute(.unique) var sessionID: UUID

        /// JSON-encoded `ActiveSessionScaffolding`.
        ///
        /// Stored as `Data` rather than as a natively-persisted Codable
        /// property because the payload contains `[UUID: ItemPlan]` — a
        /// dictionary whose keys are not strings, which `Codable` renders as a
        /// flat unkeyed array. That round-trips predictably through
        /// `JSONEncoder`; handing SwiftData's own Codable storage a shape like
        /// that is an unnecessary bet.
        var payload: Data

        /// Store-owned. Sole purpose: make the `fetchLimit = 1` Resume lookup
        /// deterministic if a store ever holds more than one journal row.
        var updatedAt: Date

        init(sessionID: UUID, payload: Data, updatedAt: Date) {
            self.sessionID = sessionID
            self.payload = payload
            self.updatedAt = updatedAt
        }
    }
}

/// The non-§1 half of an `ActiveSession`, as one Codable value.
///
/// Not a `@Model` and therefore not versioned: this is the *wire shape* of
/// `ActiveSessionJournal.payload`, which SwiftData sees only as `Data`.
///
/// Deliberately *not* the whole `ActiveSession`: `session` is stored as the
/// real §1 object graph, and journaling a second copy of it would create
/// two sources of truth that a partial write could split apart. The graph
/// is authoritative; this is only what the graph has no room for.
struct ActiveSessionScaffolding: Codable, Equatable {
    var plans: [UUID: ItemPlan]
    var restTimer: RestTimerState?
    /// m2-06 review finding 1.1: rides along so Resume can restore the
    /// exact item the lifter was viewing, not just the first one with
    /// something left to log. `Optional`, so the synthesized `Decodable`
    /// already treats a payload written before this field existed as
    /// simply absent (`nil`) rather than failing to decode -- no custom
    /// `init(from:)` needed for backward compatibility, unlike
    /// `RestTimerState`'s clamp (which has to *repair* an out-of-range
    /// value, not just tolerate a missing key).
    var currentItemID: UUID?

    init(_ active: ActiveSession) {
        self.plans = active.plans
        self.restTimer = active.restTimer
        self.currentItemID = active.currentItemID
    }
}
