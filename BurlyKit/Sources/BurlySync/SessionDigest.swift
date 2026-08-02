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
///
/// ## Generator contract — this is a trust boundary
///
/// `lastPerformance` **must be the complete latest-per-exercise derivation
/// over the phone's full history at the moment the digest is generated**
/// (spec §5: the `digest` payload carries "per-exercise last-performance
/// entries" alongside `ackedSessionIDs`, latest-wins). Not a delta, not the
/// entries touched by the sessions being acked, not "what changed since
/// last time" — the whole derivation.
///
/// The consequence that makes this load-bearing: **the absence of an entry
/// is itself an assertion.** It says the phone's history holds nothing for
/// that exercise, and the watch acts on it — pruning an acked session while
/// keeping whatever ghost rows the payload describes. A generator that
/// omits an exercise it does in fact have history for silently destroys the
/// watch's last record of it, and §5's application context is latest-wins,
/// so nothing redelivers to repair it.
///
/// The watch **cannot** verify this, and deliberately does not try (m1-06
/// review rounds E→F). It looks checkable — the store holds the sessions it
/// is about to prune, so it could demand an entry for every exercise with
/// sets in them — but that check has false positives it cannot distinguish
/// from real ones: the phone may legitimately have deleted that history
/// (§1 `deleteSession`) or edited its last sets away, while still acking
/// the session, because acked ids are retained ~30 days (§5). Refusing
/// those payloads strands the session on the watch permanently once the
/// ack ages out. So the watch trusts, and **the generator owes a property
/// test**: for any history and any ack set, the emitted `lastPerformance`
/// covers every exercise the phone has any sets for. That test belongs to
/// M4, with the generator.
public struct SessionDigestReceipt: Sendable, Equatable {
    /// The complete latest-per-exercise derivation over full phone history
    /// (§5) — see the generator contract above; an omission is an assertion
    /// the watch acts on, not a no-op. Empty is legitimate and means "the
    /// phone has no history for any exercise", which for a fresh or fully
    /// cleared phone is simply true.
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
    /// **Applies, does not audit.** The conformer takes `lastPerformance`
    /// as the complete truth about the phone's history — including what it
    /// leaves out — and prunes on that basis. Satisfying
    /// `SessionDigestReceipt`'s generator contract is the caller's
    /// obligation; there is no validation here that will catch a violation,
    /// by design, because the receiving device has no way to tell a
    /// generator bug from history the phone legitimately deleted.
    ///
    /// Not every named ID is guaranteed to disappear afterward — an ID
    /// naming an `.active` session, or no session at all, is left untouched
    /// rather than treated as an error. See
    /// `BurlyStore.applyDigest(lastPerformance:ackedSessionIDs:)` for the
    /// exact rule.
    func apply(_ receipt: SessionDigestReceipt) throws
}
