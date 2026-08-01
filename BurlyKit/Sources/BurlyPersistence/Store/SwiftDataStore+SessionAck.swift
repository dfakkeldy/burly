// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore + SessionAckApplying — wires BurlySync's minimal ack seam
// (spec §1 acceptance #6) to the watch's own pruning rule.
//
// This file is intentionally thin. All the pruning policy — which
// sessions are eligible, what happens to `.active` sessions, the
// phone-kind guard — lives on `pruneDeliveredSessions(ackedIDs:)` in
// SwiftDataStore.swift. A future M4 transport calls `apply(_:)`; this
// extension is the only place that decides what "apply" means, and it
// means exactly what the pruning method already does.

import Foundation
import BurlySync

extension SwiftDataStore: SessionAckApplying {
    public func apply(_ receipt: SessionAckReceipt) throws {
        try pruneDeliveredSessions(ackedIDs: receipt.sessionIDs)
    }
}
