// SPDX-License-Identifier: GPL-3.0-or-later
// SessionDigest — the seam between sync and the watch's local state (spec
// §5's `digest` payload; §1: "the watch never accumulates full history —
// after ack, delivered sessions are pruned from the watch store").
//
// ## The shape is the point (m1-06 review round D)
//
// §5 does not send acks on their own. `ackedSessionIDs` rides *inside* the
// `digest` payload, next to the per-exercise last-performance entries the
// same push refreshes — one latest-wins fact with two halves. An earlier
// version of this seam carried only the ids, which meant the one
// transport-facing call it offered could describe nothing but a prune, and
// the store had to be handed an empty entry list to satisfy it. That made
// each individual call atomic while leaving the *payload* splittable: the
// acked session vanishes from the watch while the numbers that were
// supposed to replace it are still in a second call that may never happen.
// Application context is latest-wins, so there is no redelivery to repair
// it.
//
// So the receipt carries both halves and there is no initializer that can
// omit one. A transport with no new entries this round says so explicitly
// (`lastPerformance: []`); it cannot say so by accident.
//
// ## Contract, and what M4 changes
//
// M4 owns the real sync protocol: a queued courier, phone-side receipt
// bookkeeping, retries, dedup, and the transport that actually moves
// digests between devices. None of that lives here yet, on purpose — this
// file is only the seam M4 will drive:
//
// - `SessionDigestReceipt` is the store-facing half of one §5 `digest`.
//   It carries no transport, ordering, or retry semantics — that is M4's
//   problem, not this type's. It also carries no `snapshotVersion`: that
//   field of the payload belongs to the catalog/routine snapshot pipeline,
//   which no store method consumes, so it stays with M4's transport rather
//   than being parked in a type whose whole job is what the store applies.
// - `SessionDigestApplying` is the one call a transport needs: "apply this
//   digest." `BurlyPersistence`'s watch-kind `SwiftDataStore` conforms to
//   it by delegating to `BurlyStore.applyDigest(lastPerformance:
//   ackedSessionIDs:)` (see `Store/SwiftDataStore+SessionDigest.swift`),
//   which lands both halves in one save. A phone-kind store derives
//   digests from full history and has no working set to prune, so it
//   throws `BurlyStoreError.operationRequiresWatchStore`.
//
// When M4 lands the real courier, it drives this same protocol against the
// same store method. Nothing here should need to change shape; only the
// caller does.
//
// This file has no BurlyPersistence dependency (BurlyPersistence depends on
// BurlySync to conform, not the reverse) and no SwiftData import: the seam
// speaks only BurlyCore value types and UUIDs.

import Foundation
import BurlyCore

/// One §5 `digest` payload, as the watch store applies it: the new
/// per-exercise last-performance entries **and** the sessions the phone has
/// durably received.
///
/// Both halves are stored properties and the initializer requires both,
/// because applying one without the other is the exact failure this type
/// exists to prevent — see the file doc.
public struct SessionDigestReceipt: Sendable, Equatable {
    /// Latest-wins per-exercise entries (§5). Empty is a legitimate digest
    /// — a push whose only news is an ack — but it has to be written out.
    public let lastPerformance: [ExerciseLastPerformanceData]

    /// IDs of sessions the phone has durably received. Carries no ordering
    /// or retry information — a transport-level concern that belongs to M4,
    /// not to this value type.
    public let ackedSessionIDs: [UUID]

    public init(
        lastPerformance: [ExerciseLastPerformanceData],
        ackedSessionIDs: [UUID]
    ) {
        self.lastPerformance = lastPerformance
        self.ackedSessionIDs = ackedSessionIDs
    }
}

/// Satisfied by the watch's store so a sync transport can apply a digest
/// without knowing anything about SwiftData, pruning mechanics, upsert
/// keys, or the `.active`/`.logged` distinction.
public protocol SessionDigestApplying: AnyObject {
    /// Applies `receipt` as one transaction: every entry upserts and every
    /// eligible acked session is pruned in the same save, or nothing
    /// happens at all.
    ///
    /// Not every named ID is guaranteed to disappear afterward — an ID
    /// naming an `.active` session, or no session at all, is left untouched
    /// rather than treated as an error. See
    /// `BurlyStore.applyDigest(lastPerformance:ackedSessionIDs:)` for the
    /// exact rule.
    func apply(_ receipt: SessionDigestReceipt) throws
}
