// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — command/callback mapping

import Foundation

/// Serialized WCSession adapter. All mutable transfer bookkeeping lives on
/// MainActor; upward delivery is serialized again onto the caller's actor.
@MainActor
public final class WCSessionAdapter: WCSessionTransportDelegate {
    private let session: any WCSessionTransport
    private let eventSink: any WCSessionAdapterEventSink
    private let payloadKinds: WCSessionPayloadKinds
    private let inspectEnvelope: OpaqueEnvelopeInspector
    private let backgroundTasks: WCBackgroundTaskCoordinator
    private var snapshotTransfers: [SnapshotTransferIdentity: any WCSessionFileTransferHandle] = [:]
    private var deliveryTail: Task<Void, Never>?

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
    /// on the caller-supplied sink actor.
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
        backgroundTasks.sessionStateChanged(
            activationState: state,
            hasContentPending: hasContentPending
        )
        emit(.activationCompleted(
            state: state,
            alreadyQueuedSessionIDs: session.outstandingSessionIDs,
            error: error
        ))
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
        deliveryTail = Task {
            await previous?.value
            await sink.receive(event)
        }
    }
}
