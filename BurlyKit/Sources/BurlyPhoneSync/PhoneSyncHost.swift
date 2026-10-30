// SPDX-License-Identifier: GPL-3.0-or-later
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
    private let session: any WCSessionTransport
    private let isWatchAppInstalled: @MainActor () -> Bool
    @ObservationIgnored private var hasRunLaunchPush = false

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
        self.session = session
        self.isWatchAppInstalled = isWatchAppInstalled
        route.handle = { [weak self] event in await self?.handle(event) }

        if coordinator.syncStateUnrecoverable {
            PhoneSyncLog.logger.error("sync journal unrecoverable; phone sync is quiescent until re-pair")
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
    public func catalogDidChange() {
        Task { await coordinator.catalogDidChange() }
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
    /// does nothing; activation itself runs the launch push.
    public func sceneDidBecomeActive() {
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
                // a fresh digest derived from store truth.
                PhoneSyncLog.logger.error("digest publish failed: \(error.description, privacy: .public)")

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
            PhoneSyncLog.logger.info("publishing digest at snapshot v\(payload.snapshotVersion, privacy: .public), \(payload.ackedSessionIDs.count, privacy: .public) acked")
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
