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
//                               transaction, both halves.
//
// Phone machine:
// - `.applySessionUpsert`     → `BurlyStore.createSession(_:)` (which takes
//                               the payload's revision at face value), plus
//                               the §5 placeholder merge of
//                               `needsNamingExercises`. On today's protocol
//                               the winning payload is always unstored —
//                               watch sessions arrive at revision 1 and only
//                               phone edits raise a stored revision — so the
//                               upsert's replace arm has no single store
//                               call yet; if a future author can win over a
//                               stored row, m4-05 owns making that replace
//                               one transaction.
// - `.publishDigest`          → derive complete `lastPerformance` from full
//                               history (the `SessionDigestReceipt`
//                               generator contract — owed a property test
//                               with the generator, m4-05), build the DTO
//                               via the initializer below, push latest-wins.
// - `.transmitSnapshot`       → build the full catalog+routine payload at
//                               that version from store truth, transfer it.
// - `.cancelSnapshotTransfer` → cancel the transport's outstanding transfer.
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
