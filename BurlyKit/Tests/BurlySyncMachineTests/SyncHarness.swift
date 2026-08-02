// SPDX-License-Identifier: GPL-3.0-or-later
// A fake transport plus both machines, wired the way m4-03/m4-05 will wire
// the real ones — and nothing else. The three §5 channels are plain
// in-memory values the tests may lose, duplicate, and reorder at will:
//
// - `sessionChannel`   — the watch→phone queued channel (transferUserInfo
//                        shaped: entries persist until a test delivers or
//                        drops them, and can be delivered twice).
// - `snapshotChannel`  — the phone→watch file channel (transferFile
//                        shaped: transfers are recorded and cancellable).
// - `latestDigest`     — the phone→watch application context (latest-wins:
//                        one slot, every publish overwrites it).
//
// Command execution mirrors the store contract's shape without any store:
// `phoneStoredRevisions` stands in for the phone's session table (what
// `storedRevision` lookups read and `applySessionUpsert` writes), and
// `watchAwaitingAck` stands in for the watch store's
// `loggedSessionsAwaitingAck()` — inserted when a session completes,
// pruned when an executed `.applyDigest` names it, exactly the §5
// convergence the paired-sim test (§5 acceptance #2/#3) will later verify
// against real stores.
import Foundation
import BurlySyncMachine

struct SyncHarness {
    typealias WatchMachine = WatchSyncMachine<String, String, String>
    typealias PhoneMachine = PhoneSyncMachine<String>

    struct QueuedSession: Equatable {
        var id: UUID
        var revision: Int
        var payload: String
    }

    struct SnapshotTransfer: Equatable {
        var version: Int
        var cancelled = false
    }

    struct DigestContext: Equatable {
        var snapshotVersion: Int
        var ackedSessionIDs: Set<UUID>
        var payload: String
    }

    let phoneMachine = PhoneMachine()
    var watchState = WatchMachine.State()
    var phoneState = PhoneMachine.State()

    /// The injected clock. Tests advance it explicitly; nothing here or in
    /// the machines reads `Date()`.
    var now = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Transport

    private(set) var sessionChannel: [QueuedSession] = []
    private(set) var snapshotChannel: [SnapshotTransfer] = []
    private(set) var latestDigest: DigestContext?

    // MARK: - Store stand-ins

    private(set) var phoneStoredRevisions: [UUID: Int] = [:]
    private(set) var phoneUpsertCount = 0
    private(set) var watchAwaitingAck: Set<UUID> = []
    private(set) var watchAppliedSnapshotVersions: [Int] = []
    private(set) var watchAppliedDigestCount = 0

    /// Revision each completed session's payload carries — side-band here
    /// because the real value lives inside the opaque payload.
    private var revisionsByID: [UUID: Int] = [:]
    private var digestCounter = 0

    // MARK: - Watch side

    /// §2 Finish: the session lands in the watch store (awaiting ack) and
    /// the machine takes it from there.
    mutating func watchCompletes(_ id: UUID, revision: Int = 1) {
        revisionsByID[id] = revision
        watchAwaitingAck.insert(id)
        runWatch(.sessionCompleted(id: id, payload: sessionPayload(id)))
    }

    mutating func watchActivates(alreadyQueued: Set<UUID> = []) {
        runWatch(.activated(alreadyQueuedSessionIDs: alreadyQueued))
    }

    mutating func watchReceivesTransferCallback(id: UUID, reportedSuccess: Bool) {
        runWatch(.sessionTransferCallback(id: id, reportedSuccess: reportedSuccess))
    }

    /// Delivers the application context's current digest, as an activation
    /// or context-arrival would.
    mutating func deliverDigestToWatch() {
        guard let digest = latestDigest else { return }
        let commands = WatchMachine.handle(
            .digestReceived(ackedSessionIDs: digest.ackedSessionIDs, payload: digest.payload),
            &watchState
        )
        for command in commands {
            switch command {
            case .applyDigest:
                // The store's applyDigest: upsert the entries (invisible
                // here) and prune every acked, logged session — one
                // transaction, replay-convergent.
                watchAwaitingAck.subtract(digest.ackedSessionIDs)
                watchAppliedDigestCount += 1
            case let .transmitSession(id, payload):
                enqueueSession(id: id, payload: payload)
            case let .applySnapshot(version, _):
                watchAppliedSnapshotVersions.append(version)
            }
        }
    }

    /// Delivers a snapshot transfer to the watch — by index so tests can
    /// deliver out of order (a superseded transfer landing late).
    mutating func deliverSnapshotToWatch(_ transfer: SnapshotTransfer) {
        runWatch(.snapshotReceived(version: transfer.version, payload: "snapshot-v\(transfer.version)"))
    }

    @discardableResult
    private mutating func runWatch(_ event: WatchMachine.Event) -> [WatchMachine.Command] {
        let commands = WatchMachine.handle(event, &watchState)
        for command in commands {
            switch command {
            case let .transmitSession(id, payload):
                enqueueSession(id: id, payload: payload)
            case let .applySnapshot(version, _):
                watchAppliedSnapshotVersions.append(version)
            case .applyDigest:
                watchAppliedDigestCount += 1
            }
        }
        return commands
    }

    // MARK: - Phone side

    /// Delivers one queued session to the phone, leaving it in the channel
    /// so tests can deliver the same entry again (double delivery, ghosts).
    mutating func deliverSessionToPhone(_ queued: QueuedSession) {
        let event = PhoneMachine.Event.sessionReceived(
            id: queued.id,
            revision: queued.revision,
            storedRevision: phoneStoredRevisions[queued.id],
            payload: queued.payload
        )
        runPhone(event, incomingRevision: queued.revision)
    }

    /// Delivers and removes the oldest queued session.
    mutating func deliverNextSessionToPhone() {
        guard !sessionChannel.isEmpty else { return }
        deliverSessionToPhone(sessionChannel.removeFirst())
    }

    mutating func phoneCatalogChanges() {
        runPhone(.catalogChanged)
    }

    mutating func phoneHistoryChanges() {
        runPhone(.historyChanged)
    }

    mutating func phoneSnapshotTransferFinishes(version: Int) {
        runPhone(.snapshotTransferFinished(version: version))
    }

    /// §1 deleteSession on the phone: the store row goes away; acks are the
    /// machine's and follow their own 30-day line.
    mutating func phoneDeletesSession(_ id: UUID) {
        phoneStoredRevisions.removeValue(forKey: id)
    }

    /// §6 phone edit: applyPhoneEdit bumps the stored revision and history
    /// changed, so the digest refreshes.
    mutating func phoneEditsSession(_ id: UUID) {
        phoneStoredRevisions[id, default: 0] += 1
        runPhone(.historyChanged)
    }

    /// Drops everything queued on the watch→phone channel — the transport
    /// losing transfers.
    mutating func loseQueuedSessions() {
        sessionChannel.removeAll()
    }

    private mutating func runPhone(_ event: PhoneMachine.Event, incomingRevision: Int? = nil) {
        let commands = phoneMachine.handle(event, &phoneState, now: now)
        for command in commands {
            switch command {
            case let .applySessionUpsert(id, _):
                // createSession takes the payload's revision at face value;
                // the harness reads it off the queued entry the way the
                // runtime reads it off the DTO.
                phoneStoredRevisions[id] = incomingRevision ?? 1
                phoneUpsertCount += 1
            case let .publishDigest(snapshotVersion, ackedSessionIDs):
                digestCounter += 1
                latestDigest = DigestContext(
                    snapshotVersion: snapshotVersion,
                    ackedSessionIDs: ackedSessionIDs,
                    payload: "digest-\(digestCounter)"
                )
            case let .transmitSnapshot(version):
                snapshotChannel.append(SnapshotTransfer(version: version))
            case let .cancelSnapshotTransfer(version):
                for index in snapshotChannel.indices where snapshotChannel[index].version == version {
                    snapshotChannel[index].cancelled = true
                }
            }
        }
    }

    // MARK: - Payload plumbing

    private func sessionPayload(_ id: UUID) -> String {
        "session-\(id.uuidString)-rev\(revisionsByID[id] ?? 1)"
    }

    private mutating func enqueueSession(id: UUID, payload: String) {
        sessionChannel.append(
            QueuedSession(id: id, revision: revisionsByID[id] ?? 1, payload: payload)
        )
    }
}
