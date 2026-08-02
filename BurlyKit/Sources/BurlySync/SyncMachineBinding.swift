// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySync — machine ⇄ wire binding
//
// `BurlySyncMachine`'s two machines run the §5 protocol over opaque
// payloads; this file is the thin layer that binds them to Burly's
// concrete wire DTOs. It is deliberately the *only* place the two vocabularies
// meet: m4-01's reviewed payloads carry BurlyCore `*Data` types directly,
// and the machines may not know a Burly domain type exists (the seam is
// build-enforced — see Package.swift's BurlySyncMachine target). The
// resolution is here: adapters extract the identity facts an event needs
// (a session's id and revision, a snapshot's version, a digest's acked
// ids) and hand the DTO through as the opaque payload, untouched.
//
// ## Command → seam mapping (m4-03/m4-05 wire these; nothing here executes)
//
// Watch machine:
// - `.transmitSession`        → encode `.session(payload)` in a
//                               `BurlySyncEnvelope`, hand to the
//                               watch→phone queued channel.
// - `.applySnapshot`          → whole-working-set replace: exercise upserts
//                               plus `BurlyStore.applyRoutineSnapshot(_:)`
//                               per routine, timestamps preserved verbatim.
// - `.applyDigest`            → `SessionDigestReceipt(applying:)` below,
//                               through `SessionDigestApplying` — one
//                               transaction: entries, pruning, and the
//                               watch's durable ack replay guard.
// - `.reportStaleSessionCompletion`
//                             → diagnostics only (log/surface): a
//                               completion replayed for an already-acked
//                               session. Nothing is transmitted and no
//                               store call is made.
//
// Phone machine:
// - `.applySessionUpsert`     → one store transaction: recheck the stored
//                               revision at the write (the event's
//                               `storedRevision` was advisory), commit iff
//                               still newer/absent — `BurlyStore
//                               .createSession(_:)` for the absent case,
//                               which takes the payload's revision at face
//                               value, plus the §5 placeholder merge of
//                               `needsNamingExercises`. On today's protocol
//                               the winning payload is always unstored —
//                               watch sessions arrive at revision 1 and only
//                               phone edits raise a stored revision — so the
//                               replace arm has no single store call yet; if
//                               a future author can win over a stored row,
//                               m4-05 owns making that replace one
//                               transaction too.
// - `.confirmSessionStored`   → atomic read: `BurlyStore.session(id:)`
//                               still holds revision ≥ the command's, on
//                               the same serialized executor as every
//                               store mutation (below).
// - `.publishDigest`          → derive complete `lastPerformance` from full
//                               history **at execution time** (the
//                               `SessionDigestReceipt` generator contract —
//                               owed a property test with the generator,
//                               m4-05), build the DTO via the initializer
//                               below, push latest-wins.
// - `.transmitSnapshot`       → build the full catalog+routine payload at
//                               that version from store truth, transfer it.
//                               The command's `generation` is the
//                               transfer's identity: key transfer
//                               bookkeeping by it and echo BOTH values
//                               into `.snapshotTransferFinished` — version
//                               alone aliases a cancelled transfer's late
//                               callback with a live same-version
//                               replacement (m4-02 review 2, #2).
// - `.cancelSnapshotTransfer` → cancel the transport's transfer for that
//                               exact `(version, generation)`.
//
// ## BINDING CONTRACT — phone session ingest (m4-05 implements and tests)
//
// This is a contract, not guidance (m4-02 review 1, #4 — which produced a
// concrete data-loss trace from a runtime that would violate it). The
// machine is restructured so an ack cannot exist except downstream of
// `.sessionStoreConfirmed`; these rules are what make that confirmation
// mean something:
//
// 1. **One serialized executor.** The revision lookup, the machine's
//    `.sessionReceived` decision, the conditional store write/verify, the
//    persistence of machine state, and the digest derivation+publication
//    for one delivery run on the same executor as every other store
//    mutation (§6 edits, deletes, imports). No store mutation interleaves
//    between a delivery's lookup and its write.
// 2. **The write is conditional.** `.applySessionUpsert` rechecks the
//    stored revision inside the store transaction and commits only if the
//    incoming revision is still greater than what is stored (or nothing
//    is). A lookup gone stale-low must not overwrite a newer row.
// 3. **Confirmation only after durability, at most once, causally
//    correlated.** `.sessionStoreConfirmed(id:)` is sent only once the
//    store durably holds a row for `id` at revision ≥ the command's — a
//    committed upsert, or a verify that found an equal/newer row — and
//    only in direct response to the specific `.applySessionUpsert` /
//    `.confirmSessionStored` command that ran: exactly one confirmation
//    per routed command, never synthesized, never replayed (m4-02
//    review 2, #3). A failed or rolled-back transaction sends nothing:
//    no confirmation, no ack, no publish; the watch's retry-until-ack
//    re-drives the exchange. The machine ignores confirmations it
//    cannot correlate to a pending routing — duplicates, crash-era
//    replays, never-routed ids — without touching ack retention, but
//    that is defense in depth, not permission to send them.
// 4. **Failed verification re-drives.** When `.confirmSessionStored`
//    finds no such row (the advisory lookup lost a race with a delete),
//    the runtime feeds the payload back through `.sessionReceived` with
//    the *current* stored revision. It must never confirm from the stale
//    decision.
// 5. **Machine state persists with the ack.** The state carrying a new
//    ack is persisted before (or atomically with) executing the
//    `publishDigest` it produced, so a crash between them re-publishes on
//    the next event instead of acking from a state that no longer exists.
// 6. **Digest publications coalesce** (m4-02 review 1, #5). Publications
//    are latest-wins and individually disposable; the runtime coalesces a
//    burst (ghost-redelivery storms, rapid confirmations) into one
//    derivation and one `updateApplicationContext` per quiet period,
//    mirroring the §5 5 s catalog-edit debounce documented on
//    `PhoneSyncMachine.Event.catalogChanged`. Correctness never depends
//    on intermediate publications — only on the newest eventually
//    landing.
//
// Imports Foundation for `UUID` only.

import Foundation
import BurlyCore
import BurlySyncMachine

/// The watch machine bound to Burly's wire payloads.
public typealias BurlyWatchSyncMachine = WatchSyncMachine<
    BurlySessionPayloadDTO,
    BurlySnapshotPayloadDTO,
    BurlyDigestPayloadDTO
>

/// The phone machine bound to Burly's wire payloads.
public typealias BurlyPhoneSyncMachine = PhoneSyncMachine<BurlySessionPayloadDTO>

extension WatchSyncMachine.Event where
    SessionPayload == BurlySessionPayloadDTO,
    SnapshotPayload == BurlySnapshotPayloadDTO,
    DigestPayload == BurlyDigestPayloadDTO
{
    /// A session finished on the watch: identity from the payload, payload
    /// through opaque.
    public static func sessionCompleted(_ payload: BurlySessionPayloadDTO) -> Self {
        .sessionCompleted(id: payload.session.id, payload: payload)
    }

    /// A decoded §5 `snapshot`: the monotonic version off the DTO, payload
    /// through opaque.
    public static func snapshotReceived(_ payload: BurlySnapshotPayloadDTO) -> Self {
        .snapshotReceived(version: payload.version, payload: payload)
    }

    /// A decoded §5 `digest`: acked ids off the DTO, payload through
    /// opaque. Set-ness is safe — a duplicated id in the wire array means
    /// the same prune.
    public static func digestReceived(_ payload: BurlyDigestPayloadDTO) -> Self {
        .digestReceived(ackedSessionIDs: Set(payload.ackedSessionIDs), payload: payload)
    }
}

extension PhoneSyncMachine.Event where SessionPayload == BurlySessionPayloadDTO {
    /// A decoded §5 `session`: id and revision off the DTO, the store's
    /// current revision for that id (`nil` when not stored) looked up by
    /// the caller — the machine keeps no revision mirror on purpose (see
    /// its file doc).
    public static func sessionReceived(
        _ payload: BurlySessionPayloadDTO,
        storedRevision: Int?
    ) -> Self {
        .sessionReceived(
            id: payload.session.id,
            revision: payload.session.revision,
            storedRevision: storedRevision,
            payload: payload
        )
    }
}

extension BurlyDigestPayloadDTO {
    /// Builds the wire digest for a `publishDigest` command: the command's
    /// machine-owned facts plus the generator-derived `lastPerformance`
    /// (see `SessionDigestReceipt` for the contract that derivation must
    /// honor). The unordered ack set is sorted so the same digest always
    /// encodes to the same bytes.
    public init(
        snapshotVersion: Int,
        lastPerformance: [ExerciseLastPerformanceData],
        ackedSessionIDs: Set<UUID>
    ) {
        self.init(
            snapshotVersion: snapshotVersion,
            lastPerformance: lastPerformance,
            ackedSessionIDs: ackedSessionIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }
}

extension SessionDigestReceipt {
    /// The store-facing half of a received digest, for executing the watch
    /// machine's `.applyDigest` command through `SessionDigestApplying`.
    /// `snapshotVersion` stays behind on purpose — the receipt's doc
    /// explains why the store never sees it.
    public init(applying payload: BurlyDigestPayloadDTO) {
        self.init(
            lastPerformance: payload.lastPerformance,
            ackedSessionIDs: payload.ackedSessionIDs
        )
    }
}
