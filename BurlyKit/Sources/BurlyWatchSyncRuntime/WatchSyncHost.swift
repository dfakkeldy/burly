// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyWatchSyncRuntime — WatchSyncHost
//
// The watch app's sync composition (m4-06): `WatchSyncCoordinator` over the
// app's one store, bound to m4-03's `WCSessionAdapter`, plus what the watch
// UI needs from sync: the phone's display unit and rest default, and a
// counter that changes whenever the working set or history did.
//
// ## Outbox retry
//
// §5: completed sessions are "transfer attempted immediately and retried on
// every app activation and WC activation callback". `sessionLogged(id:)` is
// the immediate attempt; `.activationCompleted` and `appDidBecomeActive()`
// are the two retries. Both retries pass WCSession's own outstanding
// user-info transfers as `alreadyQueuedSessionIDs`, so a session still in
// WatchConnectivity's queue is not queued twice. Transfer-finished
// callbacks are logged and nothing else: they are not delivery proof, and
// only a digest's `ackedSessionIDs` removes a session from the outbox.
//
// ## Background budget
//
// Every `WKWatchConnectivityRefreshBackgroundTask` goes to
// `retainBackgroundTask(_:)`, and the adapter completes it once WCSession is
// activated with no content pending (m4-03's invariant). The host must
// exist, and WCSession must be activating, before the app delegate's
// `handle(_:)` can run, which is why the watch app builds this at launch.
import Foundation
import Observation
import os
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncAdapters

@MainActor
@Observable
public final class WatchSyncHost {
    /// The phone's display unit from the last applied snapshot.
    public private(set) var displayUnit: WeightUnit
    /// The phone's §3 global rest default from the last applied snapshot.
    public private(set) var restDefault: TimeInterval
    /// Changes after every applied snapshot or digest. The home screen
    /// observes it to reload the routine list and "last done" text.
    public private(set) var workingSetGeneration = 0
    /// The newest envelope schema the phone sent that this build cannot
    /// read, or `nil`. Non-nil means "update Burly on Apple Watch".
    public private(set) var heldSchemaVersion: Int?

    private let store: any WatchSyncStore
    private let coordinator: WatchSyncCoordinator
    private let adapter: WCSessionAdapter
    private let session: any WCSessionTransport

    public init(store: any WatchSyncStore, session: any WCSessionTransport) throws {
        let route = WatchEventRoute()
        let state = try store.watchSyncState()
        self.store = store
        self.coordinator = try WatchSyncCoordinator(store: store)
        self.adapter = WCSessionAdapter(
            session: session,
            eventSink: WCSessionEventForwarder { event in route.handle?(event) },
            payloadKinds: WatchWCSessionWire.payloadKinds,
            inspectEnvelope: WatchWCSessionWire.inspect
        )
        self.session = session
        self.displayUnit = state.displayUnit
        self.restDefault = state.restDefault
        route.handle = { [weak self] event in self?.handle(event) }
    }

    /// Activates WCSession. Call once, at launch.
    public func activate() {
        WatchSyncLog.logger.info("activating WCSession")
        adapter.activate()
    }

    /// The app delegate's entry for every Watch Connectivity background wake.
    public func retainBackgroundTask(_ task: any WCRefreshBackgroundTask) {
        adapter.retainBackgroundTask(task)
    }

    public var retainedBackgroundTaskCount: Int { adapter.retainedBackgroundTaskCount }

    /// Finish has durably stored session `id` as logged: send it now.
    public func sessionLogged(id: UUID) {
        do {
            send(try coordinator.completedSession(id: id))
        } catch {
            WatchSyncLog.logger.error("completed session \(id.uuidString, privacy: .public) not queued: \(String(describing: error), privacy: .public)")
        }
    }

    /// §5's app-activation retry. Before WCSession activates there is
    /// nothing to queue onto; activation runs the same retry itself.
    public func appDidBecomeActive() {
        guard session.activationState == .activated else { return }
        retryOutbox(alreadyQueued: session.outstandingSessionIDs)
    }

    /// Waits until every adapter event emitted so far has been handled.
    /// Tests use it; production never needs to.
    public func flushEvents() async {
        await adapter.flushEvents()
    }

    // MARK: - Adapter events

    private func handle(_ event: WCSessionAdapterEvent) {
        switch event {
        case let .activationCompleted(state, alreadyQueued, error):
            if let error {
                WatchSyncLog.logger.error("activation error: \(error.description, privacy: .public)")
            }
            WatchSyncLog.logger.info("activation completed: \(String(describing: state), privacy: .public), \(alreadyQueued.count, privacy: .public) already queued")
            guard state == .activated else { return }
            retryOutbox(alreadyQueued: alreadyQueued)

        case let .activationStateChanged(state):
            WatchSyncLog.logger.info("activation state: \(String(describing: state), privacy: .public)")

        case let .envelopeReceived(channel, data, _):
            guard channel == .snapshotFile || channel == .digestApplicationContext else { return }
            receive(data, channel: channel)

        case let .envelopeHeld(channel, _, schemaVersion, _):
            WatchSyncLog.logger.notice("held \(channel.rawValue, privacy: .public) envelope at schema \(schemaVersion, privacy: .public); this app needs an update")
            heldSchemaVersion = max(heldSchemaVersion ?? 0, schemaVersion)

        case let .envelopeMalformed(channel, _, reason, _):
            WatchSyncLog.logger.error("malformed \(channel.rawValue, privacy: .public) envelope: \(String(describing: reason), privacy: .public)")

        case let .sessionTransferFinished(id, reportedSuccess, error):
            // Not delivery proof (§5); the digest's acks are.
            WatchSyncLog.logger.info("session \(id.uuidString, privacy: .public) transfer finished, success \(reportedSuccess, privacy: .public)\(error.map { ": \($0.description)" } ?? "", privacy: .public)")

        case .reachabilityChanged, .snapshotTransferFinished, .transportFailed:
            break
        }
    }

    private func receive(_ data: Data, channel: WCSessionChannel) {
        do {
            switch try coordinator.receive(data) {
            case let .appliedSnapshot(version):
                let state = try store.watchSyncState()
                displayUnit = state.displayUnit
                restDefault = state.restDefault
                workingSetGeneration += 1
                WatchSyncLog.logger.info("applied snapshot v\(version, privacy: .public): \(state.displayUnit.rawValue, privacy: .public), rest \(Int(state.restDefault), privacy: .public) s")
            case .appliedDigest:
                workingSetGeneration += 1
                WatchSyncLog.logger.info("applied digest")
            case let .heldNeedsAppUpdate(version):
                heldSchemaVersion = max(heldSchemaVersion ?? 0, version)
            case .ignoredStaleSnapshot:
                WatchSyncLog.logger.info("ignored stale snapshot")
            case .malformed, .ignoredWrongDirection:
                WatchSyncLog.logger.error("\(channel.rawValue, privacy: .public) envelope not applied")
            }
        } catch {
            WatchSyncLog.logger.error("\(channel.rawValue, privacy: .public) apply failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func retryOutbox(alreadyQueued: Set<UUID>) {
        do {
            send(try coordinator.activated(alreadyQueuedSessionIDs: alreadyQueued))
        } catch {
            WatchSyncLog.logger.error("outbox retry failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ result: WatchSyncExecutionResult) {
        for outbound in result.outbound {
            WatchSyncLog.logger.info("transmitting session \(outbound.id.uuidString, privacy: .public)")
            adapter.execute(.transmitSession(id: outbound.id, envelope: outbound.envelope))
        }
        // m4-05 H8: an encode failure leaves the session in the durable
        // outbox, so it retries on the next activation; say why here.
        for id in result.failedOutboundSessionIDs {
            WatchSyncLog.logger.error("session \(id.uuidString, privacy: .public) did not encode; it stays in the outbox")
        }
    }
}

@MainActor
private final class WatchEventRoute {
    var handle: (@MainActor (WCSessionAdapterEvent) -> Void)?
}

enum WatchSyncLog {
    static let logger = Logger(subsystem: "com.burly.lifting", category: "sync.watch")
}

/// Burly's wire vocabulary for the app-agnostic adapter (the phone runtime
/// has the same table; neither module depends on the other).
enum WatchWCSessionWire {
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
