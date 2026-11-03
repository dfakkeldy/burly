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
/// Every `lastPerformance` entry **must be the exact latest-per-exercise
/// derivation over the phone's full history at the moment the digest is
/// generated** (spec §5: the `digest` payload carries "per-exercise
/// last-performance entries" alongside `ackedSessionIDs`, latest-wins). Not
/// a delta, not the entries touched by the sessions being acked, not "what
/// changed since last time".
///
/// Which exercises get an entry is bounded, because the digest rides
/// `updateApplicationContext`, which refuses a payload over roughly 64 KB,
/// and a refused digest carries no acks either. The generator
/// (`SessionDigestGenerator` in BurlyPhoneSync) covers **every exercise in
/// the watch's working set that has history** — the exercises the watch can
/// start or add (`WatchWorkingSet.exercises`), not the snapshot's full
/// catalog, which also names archived unused exercises so the picker can
/// hide them — and, only when that would exceed its byte budget, drops
/// entries from the end of a fixed ranking: exercises whose latest session
/// this digest acknowledges come first, then exercises a routine starts
/// with, then the rest by most recent `performedAt`. So what goes first is
/// the longest-unperformed exercise that is neither. Exercises outside the
/// working set are never sent.
///
/// The consequence that makes this load-bearing: **the absence of an entry
/// is a claim the watch acts on.** The watch upserts the entries it is
/// given and never deletes a row for an exercise the digest leaves out, so
/// absence means "no update": the watch keeps whatever ghost row it had and
/// prunes the acked session regardless. A generator that omitted an
/// exercise whose latest numbers were in that session would leave the watch
/// showing older ones, and §5's application context is latest-wins, so
/// nothing redelivers to repair it. So the byte budget never drops such an
/// entry while acknowledging its session: those entries are kept first,
/// and if even they cannot all fit, the generator holds that session's ack
/// back for a later digest instead.
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
/// equals the full-history derivation for every working-set exercise the
/// phone has any sets for (`SessionDigestGeneratorTests`), and the byte
/// budget holds at a heavy-history scale (`DigestPayloadBoundTests`).
public struct SessionDigestReceipt: Sendable, Equatable {
    /// Exact latest-per-exercise entries for the watch's working set, as
    /// bounded above — see the generator contract; an omission is a claim
    /// the watch acts on, not a no-op. Empty is legitimate, but it does not
    /// by itself say the phone has no history. It can mean that: for a fresh
    /// or fully cleared phone it is simply true. It can also mean the byte
    /// budget was spent on the acks and routine dates alone, so no entry
    /// fit; the watch then keeps the rows it has.
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
