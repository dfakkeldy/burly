// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore + SessionAckApplying — wires BurlySync's minimal ack seam
// (spec §1 acceptance #6) to the watch's own pruning rule.
//
// This file is intentionally thin. All the pruning policy — which
// sessions are eligible, what happens to `.active` sessions, the
// phone-kind guard — lives on `applyDigest(lastPerformance:
// ackedSessionIDs:)` in SwiftDataStore.swift. A future M4 transport calls
// `apply(_:)`; this extension is the only place that decides what "apply"
// means.
//
// ## Why this routes through `applyDigest` rather than `pruneDeliveredSessions`
//
// §5 does not send acks on their own: `ackedSessionIDs` rides inside the
// `digest` payload, next to the per-exercise last-performance entries the
// same push refreshes. The m1-06 review's finding M2 is that applying
// those two halves through separate saves opens a crash window where the
// acked session is already pruned while its replacement ghost row is
// stale or missing. So the seam applies an ack as what it actually is —
// a digest whose entry list happens to be empty — and inherits that one
// transaction. When M4 lands the real courier and starts carrying entries
// too, it calls `applyDigest` directly with both halves; this receipt-
// only shape stays valid, and stays atomic, either way.

import Foundation
import BurlySync

extension SwiftDataStore: SessionAckApplying {
    public func apply(_ receipt: SessionAckReceipt) throws {
        try applyDigest(lastPerformance: [], ackedSessionIDs: receipt.sessionIDs)
    }
}
