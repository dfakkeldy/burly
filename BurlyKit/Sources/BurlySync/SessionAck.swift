// SPDX-License-Identifier: GPL-3.0-or-later
// SessionAck — the minimal ack seam between sync and the watch's working
// set (spec §1: "the watch never accumulates full history — after ack,
// delivered sessions are pruned from the watch store").
//
// ## Contract, and what M4 changes
//
// M4 owns the real sync protocol: a queued courier, phone-side receipt
// bookkeeping, retries, dedup, and the transport that actually moves acks
// between devices. None of that lives here yet, on purpose — this file is
// only the seam M4 will drive:
//
// - `SessionAckReceipt` names which sessions the phone has durably
//   received. It carries no transport, ordering, or retry semantics —
//   that is M4's problem, not this type's.
// - `SessionAckApplying` is the one call a transport needs: "apply this
//   receipt." `BurlyPersistence`'s watch-kind `SwiftDataStore` conforms to
//   it by delegating to `BurlyStore.pruneDeliveredSessions(ackedIDs:)`
//   (see `Store/SwiftDataStore+SessionAck.swift`) — the store decides what
//   "delivered" means. A phone-kind store has no working set to prune and
//   throws `BurlyStoreError.operationRequiresWatchStore`, matching the
//   digest-write gate on `upsertLastPerformance`.
//
// When M4 lands the real courier, it drives this same protocol against
// the same store method. Nothing here should need to change shape; only
// the caller does.
//
// This file has no BurlyPersistence dependency (BurlySync sits below
// BurlyPersistence in the dependency graph in the other direction —
// BurlyPersistence depends on BurlySync to conform, not the reverse) and
// no SwiftData import: the seam speaks only value types and UUIDs.

import Foundation

/// IDs of sessions the phone has durably received. Carries no ordering or
/// retry information — a transport-level concern that belongs to M4, not
/// to this value type.
public struct SessionAckReceipt: Sendable, Equatable {
    public let sessionIDs: [UUID]

    public init(sessionIDs: [UUID]) {
        self.sessionIDs = sessionIDs
    }
}

/// Satisfied by the watch's store so a sync transport can apply an ack
/// without knowing anything about SwiftData, pruning mechanics, or the
/// `.active`/`.logged` distinction.
public protocol SessionAckApplying: AnyObject {
    /// Applies `receipt`, pruning whatever sessions it names that are
    /// eligible for pruning. Not every named ID is guaranteed to
    /// disappear afterward — an ID naming an `.active` session, or no
    /// session at all, is left untouched rather than treated as an error.
    /// See `BurlyStore.pruneDeliveredSessions(ackedIDs:)` for the exact
    /// rule.
    func apply(_ receipt: SessionAckReceipt) throws
}
