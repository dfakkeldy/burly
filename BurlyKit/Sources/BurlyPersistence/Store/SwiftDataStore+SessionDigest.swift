// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore + SessionDigestApplying — wires BurlySync's §5 digest seam
// (spec §1 acceptance #6) to the watch's own digest transaction.
//
// This file is intentionally thin. All the policy — which entries upsert,
// which sessions are eligible for pruning, what happens to `.active`
// sessions, the phone-kind guard, and the single `save()` that makes the
// two halves land together — lives on `applyDigest(lastPerformance:
// ackedSessionIDs:)` in SwiftDataStore.swift. A future M4 transport calls
// `apply(_:)`; this extension is the only place that decides what "apply"
// means.
//
// The seam and the store method now describe the same payload: a receipt
// cannot be built without both halves (see BurlySync/SessionDigest.swift),
// and `applyDigest` commits both halves or neither. There is no
// transport-facing call left that can prune without the entries it was
// supposed to arrive with (m1-06 review round D).

import Foundation
import BurlySync

extension SwiftDataStore: SessionDigestApplying {
    public func apply(_ receipt: SessionDigestReceipt) throws {
        try applyDigest(
            lastPerformance: receipt.lastPerformance,
            ackedSessionIDs: receipt.ackedSessionIDs
        )
    }
}
