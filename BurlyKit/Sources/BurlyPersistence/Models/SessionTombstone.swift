// SPDX-License-Identifier: GPL-3.0-or-later
// SessionTombstone — the phone's record that the user deleted a session.
//
// ## Why a deleted session needs a row at all
//
// The watch keeps every finished session until it sees that session's id
// in a digest's `ackedSessionIDs` (§5 outbox), and it re-sends on every
// activation until then. A session the user deletes on the phone may still
// be sitting in that outbox — the watch was off, out of range, or simply
// had not received the newest digest yet — so the phone can receive the
// same session again *after* the delete. §5's apply rule treats "nothing
// stored" as "create", so without a record of the delete that re-delivery
// would put the deleted workout straight back into History and Stats.
//
// A tombstone is that record: `deleteLoggedSession(id:)` writes one in the
// same save that deletes the session, and the replicated apply refuses to
// re-create any id that has one. The delivery is still acknowledged, so
// the watch prunes its copy and stops re-sending.
//
// ## Never pruned
//
// The phone forgets acks after 30 days (§5), but a watch that was offline
// for longer still holds the session and will re-deliver it. The ack is
// re-earned then; the tombstone is what keeps the session from coming back
// with it. A tombstone is a UUID and a date, and only a deliberate user
// delete writes one, so keeping them for good costs nothing worth saving.
//
// ## Registering it in V1
//
// Same reasoning as `CatalogSeedState` and `WatchSyncJournal`:
// BurlySchemaV1 has not shipped, so adding this model to V1 is an additive
// completion of the initial schema, not a migration of user data. It is
// module-internal bookkeeping, not a §1 domain entity, and nothing about
// it crosses the sync wire. Nested in `BurlySchemaV1` like every other
// model — see Schema/CurrentSchema.swift.

import Foundation
import SwiftData

extension BurlySchemaV1 {
    @Model
    final class SessionTombstone {
        /// The deleted `Session`'s id. Unique: a session is deleted once.
        @Attribute(.unique) var sessionID: UUID

        /// Store-owned (the store's clock at delete time). Diagnostic only:
        /// nothing reads it to decide anything.
        var deletedAt: Date

        init(sessionID: UUID, deletedAt: Date) {
            self.sessionID = sessionID
            self.deletedAt = deletedAt
        }
    }
}
