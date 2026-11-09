// SPDX-License-Identifier: MIT
// BurlySyncAdapters — command/callback mapping

import Foundation

/// Serialized WCSession adapter. All mutable transfer bookkeeping lives on
/// MainActor; upward delivery is serialized again onto the caller's actor.
///
/// ## Background tasks wait for the apply
///
/// A retained `WKWatchConnectivityRefreshBackgroundTask` completes only once
/// WCSession is activated with no content pending *and* every content event
/// emitted so far has been handled by the sink: received and held
/// envelopes, and activation completion (the outbox retry runs there).
/// WCSession clears `hasContentPending` as soon as its delegate received the
/// content, while the apply runs later, behind this adapter's delivery chain
/// and the sink's actor hop. The KVO hop that reports the cleared flag is a
/// separate main-actor task, so without this gate it could complete the task
/// while a snapshot or digest WatchConnectivity already handed over was
/// still unwritten. The gate relies on the content reaching this adapter
/// before the cleared flag does: WCSession calls the delegate for content
/// before it clears `hasContentPending`, and `SystemWCSessionTransport`
/// submits both hops to the main queue, which keeps submission order.
@MainActor
public final class WCSessionAdapter: WCSessionTransportDelegate {
    private let session: any WCSessionTransport
    private let eventSink: any WCSessionAdapterEventSink
    private let payloadKinds: WCSessionPayloadKinds
    private let inspectEnvelope: OpaqueEnvelopeInspector
    private let backgroundTasks: WCBackgroundTaskCoordinator
    private var snapshotTransfers: [SnapshotTransferIdentity: any WCSessionFileTransferHandle] = [:]
    private var deliveryTail: Task<Void, Never>?
    /// Content events emitted and not yet handled by the sink.
    private var undeliveredContentCount = 0

    public init(
        session: any WCSessionTransport,
        eventSink: any WCSessionAdapterEventSink,
        payloadKinds: WCSessionPayloadKinds,
        inspectEnvelope: @escaping OpaqueEnvelopeInspector
    ) {
        self.session = session
        self.eventSink = eventSink
        self.payloadKinds = payloadKinds
        self.inspectEnvelope = inspectEnvelope
        backgroundTasks = WCBackgroundTaskCoordinator(
            activationState: session.activationState,
            hasContentPending: session.hasContentPending
        )
        session.delegate = self
    }

    public var retainedBackgroundTaskCount: Int { backgroundTasks.retainedTaskCount }

    public func activate() {
        session.activate()
    }

    public func retainBackgroundTask(_ task: any WCRefreshBackgroundTask) {
        backgroundTasks.retain(task)
    }

    public func execute(_ command: WatchWCSessionCommand) {
        switch command {
        case let .transmitSession(id, envelope):
            session.transferUserInfo(
                envelope: envelope,
                metadata: WCSessionTransferMetadata(kind: payloadKinds.session, sessionID: id)
            )
        }
    }

    public func execute(_ command: PhoneWCSessionCommand) {
        switch command {
        case let .transmitSnapshot(identity, envelope):
            // Enforce the channel-level supersession rule even if a caller
            // bypasses the machine's explicit cancel-then-transmit pair.
            let superseded = snapshotTransfers.keys.filter { $0.version < identity.version }
            for oldIdentity in superseded {
                snapshotTransfers.removeValue(forKey: oldIdentity)?.cancel()
            }

            // A retry can carry the exact same version and generation. Do
            // not orphan its prior OS handle when replacing the dictionary
            // entry; its eventual callback would otherwise be uncorrelatable.
            snapshotTransfers.removeValue(forKey: identity)?.cancel()

            do {
                snapshotTransfers[identity] = try session.transferFile(
                    envelope: envelope,
                    metadata: WCSessionTransferMetadata(
                        kind: payloadKinds.snapshot,
                        snapshot: identity
                    )
                )
            } catch {
                emit(.transportFailed(
                    operation: .transmitSnapshot(identity),
                    error: WCSessionTransportError(error)
                ))
            }

        case let .cancelSnapshotTransfer(identity):
            snapshotTransfers.removeValue(forKey: identity)?.cancel()

        case let .publishDigest(envelope):
            do {
                try session.updateApplicationContext(
                    envelope: envelope,
                    metadata: WCSessionTransferMetadata(kind: payloadKinds.digest)
                )
            } catch {
                emit(.transportFailed(
                    operation: .publishDigest,
                    error: WCSessionTransportError(error)
                ))
            }
        }
    }

    /// Test and shutdown seam: waits until every event emitted so far has run
    /// on the caller-supplied sink actor, and any background task that was
    /// waiting on them has been completed.
    public func flushEvents() async {
        await deliveryTail?.value
    }

    public func transportSessionStateDidChange(
        activationState: WCSessionActivation,
        hasContentPending: Bool
    ) {
        backgroundTasks.sessionStateChanged(
            activationState: activationState,
            hasContentPending: hasContentPending
        )
        emit(.activationStateChanged(activationState))
    }

    public func transportActivationDidComplete(
        state: WCSessionActivation,
        hasContentPending: Bool,
        error: WCSessionTransportError?
    ) {
        // A digest delivered on an earlier launch can be lost: WCSession
        // counts it delivered once the delegate got it, and the app may be
        // suspended before the apply ran. It stays in
        // `receivedApplicationContext`, and nothing re-sends it until the
        // phone's history changes. Re-reading it here is safe because the
        // channel is latest-wins and the apply is idempotent; it goes first
        // so its acks prune the outbox before activation retries it.
        if state == .activated, let context = session.receivedApplicationContext {
            transportDidReceive(
                channel: .digestApplicationContext,
                data: context.envelope,
                metadata: context.metadata
            )
        }
        emit(.activationCompleted(
            state: state,
            alreadyQueuedSessionIDs: session.outstandingSessionIDs,
            error: error
        ))
        backgroundTasks.sessionStateChanged(
            activationState: state,
            hasContentPending: hasContentPending
        )
    }

    public func transportReachabilityDidChange(_ reachable: Bool) {
        emit(.reachabilityChanged(reachable))
    }

    public func transportDidReceive(
        channel: WCSessionChannel,
        data: Data,
        metadata: WCSessionTransferMetadata
    ) {
        switch inspectEnvelope(data) {
        case let .accepted(kind):
            let expected = payloadKinds.kind(for: channel)
            guard kind == expected else {
                emit(.envelopeMalformed(
                    channel: channel,
                    data: data,
                    reason: .unexpectedKind(expected: expected, actual: kind),
                    metadata: metadata
                ))
                return
            }
            emit(.envelopeReceived(channel: channel, data: data, metadata: metadata))

        case let .heldNeedsAppUpdate(schemaVersion):
            emit(.envelopeHeld(
                channel: channel,
                data: data,
                schemaVersion: schemaVersion,
                metadata: metadata
            ))

        case let .malformed(reason):
            emit(.envelopeMalformed(
                channel: channel,
                data: data,
                reason: .inspectorRejected(reason),
                metadata: metadata
            ))
        }
    }

    public func transportDidReceiveMalformed(
        channel: WCSessionChannel,
        reason: WCSessionMalformedEnvelopeReason,
        metadata: WCSessionTransferMetadata?
    ) {
        emit(.envelopeMalformed(channel: channel, data: nil, reason: reason, metadata: metadata))
    }

    public func transportSessionTransferDidFinish(
        id: UUID,
        error: WCSessionTransportError?
    ) {
        emit(.sessionTransferFinished(id: id, reportedSuccess: error == nil, error: error))
    }

    public func transportSnapshotTransferDidFinish(
        identity: SnapshotTransferIdentity,
        error: WCSessionTransportError?
    ) {
        snapshotTransfers.removeValue(forKey: identity)
        emit(.snapshotTransferFinished(
            identity: identity,
            reportedSuccess: error == nil,
            error: error
        ))
    }

    private func emit(_ event: WCSessionAdapterEvent) {
        let previous = deliveryTail
        let sink = eventSink
        let isContent = Self.isContent(event)
        if isContent {
            undeliveredContentCount += 1
            if undeliveredContentCount == 1 {
                backgroundTasks.undeliveredContentChanged(to: true)
            }
        }
        deliveryTail = Task { [weak self] in
            await previous?.value
            await sink.receive(event)
            if isContent { self?.contentDelivered() }
        }
    }

    private func contentDelivered() {
        undeliveredContentCount -= 1
        if undeliveredContentCount == 0 {
            backgroundTasks.undeliveredContentChanged(to: false)
        }
    }

    /// The events a background wake must see handled before it ends: what
    /// WatchConnectivity handed over, and activation completion, which runs
    /// the outbox retry. Transfer-finish facts and plain state changes are
    /// not, so they never hold a task open.
    private static func isContent(_ event: WCSessionAdapterEvent) -> Bool {
        switch event {
        case .envelopeReceived, .envelopeHeld, .activationCompleted:
            true
        case .activationStateChanged, .reachabilityChanged, .envelopeMalformed,
             .sessionTransferFinished, .snapshotTransferFinished, .transportFailed:
            false
        }
    }
}
