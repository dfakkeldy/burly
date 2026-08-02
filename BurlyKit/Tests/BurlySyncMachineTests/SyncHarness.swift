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
// Command execution mirrors the store contract's shape without any store,
// including the m4-02 review-1 binding contract for phone ingest:
// `phoneStoredRevisions`/`phoneStoredPayloads` stand in for the phone's
// session table; `.applySessionUpsert` **rechecks the revision at the
// write** and `.confirmSessionStored` verifies-or-re-drives, and only a
// durable outcome feeds `.sessionStoreConfirmed` back (contract items
// 2–4). Test hooks deliberately violate the runtime's own assumptions to
// reproduce the review's races: `deliverSessionToPhone(_:staleStored
// Revision:)` injects a lookup that a concurrent mutation has already
// invalidated, and `failNextUpsertCommit` makes the next conditional
// upsert's transaction fail (no confirmation — contract item 3).
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

    /// The injected clock. Tests advance (or roll back) it explicitly;
    /// nothing here or in the machines reads `Date()`.
    var now = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Transport

    private(set) var sessionChannel: [QueuedSession] = []
    private(set) var snapshotChannel: [SnapshotTransfer] = []
    private(set) var latestDigest: DigestContext?

    // MARK: - Store stand-ins

    private(set) var phoneStoredRevisions: [UUID: Int] = [:]
    private(set) var phoneStoredPayloads: [UUID: String] = [:]
    private(set) var phoneUpsertCount = 0
    private(set) var watchAwaitingAck: Set<UUID> = []
    private(set) var watchAppliedSnapshotVersions: [Int] = []
    private(set) var watchAppliedDigestCount = 0

    // MARK: - Fault injection

    /// The next `.applySessionUpsert` transaction fails after the machine
    /// commanded it: nothing commits, nothing confirms (binding contract
    /// item 3).
    var failNextUpsertCommit = false

    /// Revision each completed session's payload carries — side-band here
    /// because the real value lives inside the opaque payload.
    private var revisionsByID: [UUID: Int] = [:]
    private var digestCounter = 0

    // MARK: - Watch side

    /// §2 Finish: the session lands in the watch store (awaiting ack) and
    /// the machine takes it from there. `payload` defaults to a canonical
    /// serialization; tests exercising conflicting same-id completions
    /// pass their own.
    mutating func watchCompletes(_ id: UUID, revision: Int = 1, payload: String? = nil) {
        revisionsByID[id] = revision
        watchAwaitingAck.insert(id)
        runWatch(.sessionCompleted(id: id, payload: payload ?? sessionPayload(id)))
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

    /// Delivers a snapshot transfer to the watch — by value so tests can
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
    ///
    /// `staleStoredRevision` injects a lookup that a concurrent store
    /// mutation has already invalidated — the m4-02 review-1 TOCTOU
    /// races. `.some(nil)` means "the stale lookup saw no row"; omit it
    /// for an honest, current lookup.
    mutating func deliverSessionToPhone(
        _ queued: QueuedSession,
        staleStoredRevision: Int?? = nil
    ) {
        let storedRevision = staleStoredRevision ?? phoneStoredRevisions[queued.id]
        let commands = phoneMachine.handle(
            .sessionReceived(
                id: queued.id,
                revision: queued.revision,
                storedRevision: storedRevision,
                payload: queued.payload
            ),
            &phoneState,
            now: now
        )
        execute(commands, delivering: queued)
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

    mutating func phoneSnapshotPushTriggers() {
        runPhone(.snapshotPushTriggered)
    }

    mutating func phoneSnapshotTransferFinishes(version: Int) {
        runPhone(.snapshotTransferFinished(version: version))
    }

    /// §1 deleteSession on the phone: the store row goes away; acks are the
    /// machine's and follow their own 30-day line.
    mutating func phoneDeletesSession(_ id: UUID) {
        phoneStoredRevisions.removeValue(forKey: id)
        phoneStoredPayloads.removeValue(forKey: id)
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

    private mutating func runPhone(_ event: PhoneMachine.Event) {
        let commands = phoneMachine.handle(event, &phoneState, now: now)
        execute(commands, delivering: nil)
    }

    /// Executes phone commands per the binding contract. `delivering` is
    /// the queued entry currently being processed — the payload in hand
    /// that a failed `.confirmSessionStored` verification re-drives
    /// (contract item 4).
    private mutating func execute(
        _ commands: [PhoneMachine.Command],
        delivering queued: QueuedSession?
    ) {
        for command in commands {
            switch command {
            case let .applySessionUpsert(id, revision, payload):
                if failNextUpsertCommit {
                    // The transaction failed: nothing committed, nothing
                    // confirmed (contract item 3). The watch retries.
                    failNextUpsertCommit = false
                    break
                }
                // Contract item 2: the write rechecks the revision inside
                // the transaction; a stale-low lookup must not overwrite a
                // newer row.
                if phoneStoredRevisions[id].map({ revision > $0 }) ?? true {
                    phoneStoredRevisions[id] = revision
                    phoneStoredPayloads[id] = payload
                    phoneUpsertCount += 1
                }
                // Either way the store now durably holds ≥ revision.
                confirmSessionStored(id)

            case let .confirmSessionStored(id, revision):
                if let stored = phoneStoredRevisions[id], stored >= revision {
                    confirmSessionStored(id)
                } else if let queued {
                    // Contract item 4: the advisory lookup lost a race —
                    // re-drive with the current stored revision instead of
                    // confirming from the stale decision.
                    deliverSessionToPhone(queued)
                }

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

    /// Contract item 3: the store durably holds the row — only now does
    /// the machine learn about it, earn the ack, and publish.
    private mutating func confirmSessionStored(_ id: UUID) {
        let commands = phoneMachine.handle(.sessionStoreConfirmed(id: id), &phoneState, now: now)
        execute(commands, delivering: nil)
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
