// SPDX-License-Identifier: MIT
// BurlyPhoneSync — PhoneSyncHost
//
// The phone app's sync composition (m4-06): one `PhoneSyncCoordinator`
// over the app's one store, bound to m4-03's `WCSessionAdapter`. The
// coordinator speaks DTOs and the adapter speaks opaque envelope bytes;
// this file is the only place the two meet on the phone.
//
// ## What the host decides, and why
//
// - **Pushes wait for activation.** WCSession refuses `transferFile` and
//   `updateApplicationContext` before it is activated, so §5's launch push
//   fires from the first `.activationCompleted(.activated)`, not from app
//   start. If the watch app is installed at that moment, the install edge
//   (`watchAppInstalledDidChange(true)`) *is* the launch push; calling both
//   would cancel and resend the same version for nothing.
// - **A transport failure is a finished transfer.** The adapter never
//   throws into the coordinator; a `transferFile` that could not start comes
//   back as `.transportFailed(.transmitSnapshot)`. It is echoed to the
//   coordinator exactly like a failed completion callback, or the machine's
//   outstanding-transfer slot would never clear.
// - **No sync failure reaches the user's edit.** The app's edit paths call
//   `catalogDidChange()` / `historyDidChange()` and move on; failures are
//   logged here. The edit is already durable in the store, and §5's push
//   triggers (launch, daily, the next edit) re-send from store truth.
// - **A newer peer is surfaced, not parsed.** `.envelopeHeld` records the
//   schema version in `heldSchemaVersion` for the app to show "update
//   Burly". The watch keeps the session until it is acked, so nothing is
//   lost while this phone waits for the update.
// - **An unrecoverable journal is reset in the foreground, never at
//   launch.** A journal that exists but holds no valid record leaves the
//   coordinator quiescent (`syncStateUnrecoverable`): no push, no digest, no
//   session ingest. Its only exit is `resetSyncStateForRePair()`, and
//   without a caller sync stayed off for the life of the install. The same
//   flag is also set when the journal could not be *read* at all, which can
//   be temporary: iOS data protection on a background launch before the
//   first unlock. Resetting then would replace a good identity line with a
//   fresh one. So the host waits for the first foreground
//   (`sceneDidBecomeActive()`: the device is unlocked) and loads the journal
//   again. If it is still unrecoverable, the host resets it, logs that, and
//   runs the launch push. The realistic cause is a first write that was torn
//   or hit a full disk, and the coordinator persists before it transmits,
//   so that identity line never reached the watch. A journal corrupted
//   after it had sent snapshots costs what the reset's contract says: the
//   watch ignores the restarted snapshot versions until they pass the one
//   it applied, while sessions, acks and digests flow again. If the journal
//   now loads, the failure was transient: nothing is reset, and sync
//   resumes on the next launch.
import Foundation
import Observation
import os
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncAdapters

@MainActor
@Observable
public final class PhoneSyncHost {
    /// The newest envelope schema the watch sent that this build cannot
    /// read, or `nil`. Non-nil means "update Burly on iPhone".
    public private(set) var heldSchemaVersion: Int?

    /// Called on the main actor after a watch session was ingested, so the
    /// app can refresh History and Stats.
    @ObservationIgnored public var onHistoryChanged: (@MainActor () -> Void)?

    public let coordinator: PhoneSyncCoordinator
    private let adapter: WCSessionAdapter
    private let bridge: PhoneWCSessionBridge
    private let session: any WCSessionTransport
    private let statePersisting: any PhoneSyncStatePersisting
    private let isWatchAppInstalled: @MainActor () -> Bool
    @ObservationIgnored private var hasRunLaunchPush = false
    /// Set once the foreground check of an unrecoverable journal (see the
    /// file doc) has settled, by a reset or by finding it readable again.
    @ObservationIgnored private var journalRecoverySettled = false
    /// The launch push a journal reset runs. Tests await it.
    @ObservationIgnored private(set) var journalResetPush: Task<Void, Never>?

    public init(
        store: any BurlyStore,
        session: any WCSessionTransport,
        statePersisting: any PhoneSyncStatePersisting,
        watchSettings: @escaping @MainActor () -> PhoneWatchSettings,
        isWatchAppInstalled: @escaping @MainActor () -> Bool,
        clock: any WallClock = SystemWallClock(),
        scheduler: any TriggerScheduling = SystemTriggerScheduler(),
        configuration: PhoneSyncCoordinator.Configuration = .init()
    ) {
        let bridge = PhoneWCSessionBridge()
        let route = PhoneEventRoute()
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: bridge,
            digestPublisher: bridge,
            statePersisting: statePersisting,
            clock: clock,
            scheduler: scheduler,
            configuration: configuration,
            watchSettings: watchSettings
        )
        let adapter = WCSessionAdapter(
            session: session,
            eventSink: WCSessionEventForwarder { event in await route.handle?(event) },
            payloadKinds: BurlyWCSessionWire.payloadKinds,
            inspectEnvelope: BurlyWCSessionWire.inspect
        )
        bridge.adapter = adapter
        self.coordinator = coordinator
        self.adapter = adapter
        self.bridge = bridge
        self.session = session
        self.statePersisting = statePersisting
        self.isWatchAppInstalled = isWatchAppInstalled
        route.handle = { [weak self] event in await self?.handle(event) }

        if coordinator.syncStateUnrecoverable {
            PhoneSyncLog.logger.error("sync journal unrecoverable; phone sync is quiescent until the app is in the foreground, then it is checked again")
        } else if coordinator.recoveredFromCorruptState {
            PhoneSyncLog.logger.notice("sync journal recovered from corruption")
        }
    }

    /// Activates WCSession. Call once, at launch, after the store resolved.
    public func activate() {
        PhoneSyncLog.logger.info("activating WCSession")
        adapter.activate()
    }

    /// Waits until every adapter event emitted so far has been handled.
    /// Tests use it; production never needs to.
    public func flushEvents() async {
        await adapter.flushEvents()
    }

    // MARK: - App triggers

    /// §5 "on any routine/catalog edit (debounced 5 s)" — and the two
    /// watch-facing Settings rows, which ride the snapshot.
    ///
    /// The digest is refreshed too: it is bounded to the exercises the
    /// watch can still show, ranks routine exercises first and reports
    /// routine dates, so a catalog or routine edit can change what it
    /// should hold without any history changing. Coalesced and latest-wins,
    /// like every digest publish.
    public func catalogDidChange() {
        Task { await coordinator.catalogDidChange() }
        historyDidChange()
    }

    /// §5 "Digest is refreshed whenever history changes".
    public func historyDidChange() {
        Task {
            do {
                try await coordinator.historyDidChange()
            } catch {
                PhoneSyncLog.logger.error("history-changed digest failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The app came to the foreground: §5's daily push and the install edge
    /// get their chance to fire. Before WCSession activation completes this
    /// does nothing; activation itself runs the launch push. It is also when
    /// an unrecoverable sync journal is checked again and reset (file doc).
    public func sceneDidBecomeActive() {
        guard !coordinator.syncStateUnrecoverable else {
            // Every push is gated while quiescent; a reset runs the launch
            // push itself.
            resetUnrecoverableJournalIfConfirmed()
            return
        }
        guard hasRunLaunchPush, session.activationState == .activated else { return }
        Task {
            do {
                try await coordinator.watchAppInstalledDidChange(isWatchAppInstalled())
                try await coordinator.dailyPushIfDue()
            } catch {
                PhoneSyncLog.logger.error("foreground push failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Unrecoverable journal

    /// The foreground check of an unrecoverable journal (file doc). After a
    /// reset the launch push runs in `journalResetPush` if activation already
    /// ran its no-op one, and from activation otherwise.
    private func resetUnrecoverableJournalIfConfirmed() {
        guard !journalRecoverySettled else { return }
        do {
            _ = try statePersisting.load()
            journalRecoverySettled = true
            PhoneSyncLog.logger.notice("sync journal is readable in the foreground; it was unreadable at launch, so nothing is reset and sync resumes on the next launch")
            return
        } catch is PhoneSyncStateUnrecoverableError {
            // Still unrecoverable with the device unlocked: reset below.
        } catch {
            journalRecoverySettled = true
            PhoneSyncLog.logger.error("sync journal check failed, not resetting: \(String(describing: error), privacy: .public)")
            return
        }
        do {
            try coordinator.resetSyncStateForRePair()
        } catch {
            // The old journal is intact and the coordinator still quiescent;
            // the next foreground tries again.
            PhoneSyncLog.logger.error("sync journal reset failed: \(String(describing: error), privacy: .public)")
            return
        }
        journalRecoverySettled = true
        PhoneSyncLog.logger.notice("sync journal still unrecoverable in the foreground; reset to a fresh sync identity")
        guard hasRunLaunchPush else { return }
        hasRunLaunchPush = false
        journalResetPush = Task {
            do {
                try await runLaunchPushIfNeeded()
            } catch {
                PhoneSyncLog.logger.error("launch push after journal reset failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Adapter events

    private func handle(_ event: WCSessionAdapterEvent) async {
        do {
            switch event {
            case let .activationCompleted(state, _, error):
                if let error {
                    PhoneSyncLog.logger.error("activation error: \(error.description, privacy: .public)")
                }
                PhoneSyncLog.logger.info("activation completed: \(String(describing: state), privacy: .public)")
                guard state == .activated else { return }
                try await runLaunchPushIfNeeded()

            case let .activationStateChanged(state):
                PhoneSyncLog.logger.info("activation state: \(String(describing: state), privacy: .public)")

            case let .envelopeReceived(channel, data, _):
                guard channel == .sessionUserInfo else { return }
                guard case let .decoded(envelope) = BurlySyncEnvelope.decode(data),
                      case let .session(payload) = envelope.payload
                else {
                    PhoneSyncLog.logger.error("session envelope did not decode after inspection")
                    return
                }
                PhoneSyncLog.logger.info("session received: \(payload.session.id.uuidString, privacy: .public) revision \(payload.session.revision, privacy: .public)")
                try await coordinator.sessionReceived(payload)
                onHistoryChanged?()

            case let .envelopeHeld(channel, _, schemaVersion, _):
                PhoneSyncLog.logger.notice("held \(channel.rawValue, privacy: .public) envelope at schema \(schemaVersion, privacy: .public); this app needs an update")
                heldSchemaVersion = max(heldSchemaVersion ?? 0, schemaVersion)

            case let .envelopeMalformed(channel, _, reason, _):
                PhoneSyncLog.logger.error("malformed \(channel.rawValue, privacy: .public) envelope: \(String(describing: reason), privacy: .public)")

            case let .snapshotTransferFinished(identity, reportedSuccess, error):
                PhoneSyncLog.logger.info("snapshot v\(identity.version, privacy: .public) g\(identity.generation, privacy: .public) finished, success \(reportedSuccess, privacy: .public)\(error.map { ": \($0.description)" } ?? "", privacy: .public)")
                try await coordinator.snapshotTransferFinished(version: identity.version, generation: identity.generation)

            case let .transportFailed(.transmitSnapshot(identity), error):
                PhoneSyncLog.logger.error("snapshot v\(identity.version, privacy: .public) g\(identity.generation, privacy: .public) could not start: \(error.description, privacy: .public)")
                try await coordinator.snapshotTransferFinished(version: identity.version, generation: identity.generation)

            case let .transportFailed(.publishDigest, error):
                // Latest-wins: the next history change or launch publishes
                // a fresh digest derived from store truth. The size is the
                // first thing to know: an oversized payload fails the same
                // way every time (see `SessionDigestGenerator`'s budget).
                let size = bridge.lastDigestEnvelopeByteCount.map { "\($0) bytes" } ?? "size unknown"
                PhoneSyncLog.logger.error("digest publish failed (\(size, privacy: .public)): \(error.description, privacy: .public)")

            case .reachabilityChanged, .sessionTransferFinished:
                break
            }
        } catch {
            PhoneSyncLog.logger.error("sync event failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func runLaunchPushIfNeeded() async throws {
        guard !hasRunLaunchPush else {
            // A reactivation (watch switch): re-check the install edge only.
            try await coordinator.watchAppInstalledDidChange(isWatchAppInstalled())
            return
        }
        hasRunLaunchPush = true
        if isWatchAppInstalled() {
            PhoneSyncLog.logger.info("launch push via install edge")
            try await coordinator.watchAppInstalledDidChange(true)
        } else {
            PhoneSyncLog.logger.info("launch push; watch app not reported installed")
            try await coordinator.applicationDidLaunch()
        }
        // A fresh watch needs the digest as well as the snapshot (ghosts,
        // prefill, acks). Coalesced and latest-wins, so this is cheap.
        try await coordinator.historyDidChange()
    }
}

/// The `PhoneSyncTransporting` / `PhoneDigestPublishing` conformer: encodes
/// the DTO into an envelope and hands the bytes to the adapter. It never
/// throws; the adapter reports a transfer that could not start as an event.
@MainActor
final class PhoneWCSessionBridge: PhoneSyncTransporting, PhoneDigestPublishing {
    weak var adapter: WCSessionAdapter?
    /// The size of the last digest envelope handed to the adapter. A failed
    /// `updateApplicationContext` comes back later as an event with no
    /// payload, so the host reads the size from here to log it. A newer
    /// publish can land before that event, in which case the logged size is
    /// the newer digest's; digests are coalesced, so that is rare and the
    /// two are usually close in size.
    private(set) var lastDigestEnvelopeByteCount: Int?

    func transmitSnapshot(_ payload: BurlySnapshotPayloadDTO, generation: Int) async throws {
        let envelope = try BurlySyncEnvelope(payload: .snapshot(payload)).encodedData()
        PhoneSyncLog.logger.info("transmitting snapshot v\(payload.version, privacy: .public) g\(generation, privacy: .public): \(payload.routines.count, privacy: .public) routines, \(payload.exercises.count, privacy: .public) exercises, \(payload.displayUnit.rawValue, privacy: .public), rest \(Int(payload.restDefault), privacy: .public) s")
        adapter?.execute(.transmitSnapshot(
            identity: SnapshotTransferIdentity(version: payload.version, generation: generation),
            envelope: envelope
        ))
    }

    func cancelSnapshotTransfer(version: Int, generation: Int) async throws {
        adapter?.execute(.cancelSnapshotTransfer(
            identity: SnapshotTransferIdentity(version: version, generation: generation)
        ))
    }

    func publishDigest(_ payload: BurlyDigestPayloadDTO) async {
        do {
            let envelope = try BurlySyncEnvelope(payload: .digest(payload)).encodedData()
            lastDigestEnvelopeByteCount = envelope.count
            PhoneSyncLog.logger.info("publishing digest at snapshot v\(payload.snapshotVersion, privacy: .public), \(payload.ackedSessionIDs.count, privacy: .public) acked, \(payload.lastPerformance.count, privacy: .public) exercises, \(payload.routineLastPerformed?.count ?? 0, privacy: .public) routines, \(envelope.count, privacy: .public) bytes")
            adapter?.execute(.publishDigest(envelope: envelope))
        } catch {
            PhoneSyncLog.logger.error("digest did not encode: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Late-bound route from the adapter's sink to the host, which does not
/// exist yet when the adapter is built.
@MainActor
private final class PhoneEventRoute {
    var handle: (@MainActor (WCSessionAdapterEvent) async -> Void)?
}

enum PhoneSyncLog {
    static let logger = Logger(subsystem: "com.burly.lifting", category: "sync.phone")
}

/// Burly's wire vocabulary for the app-agnostic adapter: the three §5 kind
/// strings, and an inspector that is `BurlySyncEnvelope.decode` itself, so
/// the adapter's held/malformed routing is the envelope's own policy.
enum BurlyWCSessionWire {
    static let payloadKinds = WCSessionPayloadKinds(
        snapshot: BurlySyncPayloadKind.snapshot.rawValue,
        session: BurlySyncPayloadKind.session.rawValue,
        digest: BurlySyncPayloadKind.digest.rawValue
    )

    @Sendable
    static func inspect(_ data: Data) -> OpaqueEnvelopeInspection {
        switch BurlySyncEnvelope.decode(data) {
        case let .decoded(envelope):
            .accepted(kind: envelope.kind.rawValue)
        case let .heldNeedsAppUpdate(version):
            .heldNeedsAppUpdate(schemaVersion: version)
        case let .malformed(error):
            .malformed(reason: String(describing: error))
        }
    }
}
