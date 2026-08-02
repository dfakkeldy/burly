// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — app-agnostic Watch Connectivity vocabulary

import Foundation

/// The three transport channels whose delivery semantics are fixed by §5.
public enum WCSessionChannel: String, Sendable, Equatable {
    case snapshotFile
    case sessionUserInfo
    case digestApplicationContext
}

/// Wire discriminator strings are injected so this target never imports a
/// Burly DTO or assumes that another app uses Burly's payload-kind names.
public struct WCSessionPayloadKinds: Sendable, Equatable {
    public let snapshot: String
    public let session: String
    public let digest: String

    public init(snapshot: String, session: String, digest: String) {
        precondition(!snapshot.isEmpty && !session.isEmpty && !digest.isEmpty)
        precondition(Set([snapshot, session, digest]).count == 3)
        self.snapshot = snapshot
        self.session = session
        self.digest = digest
    }

    public func kind(for channel: WCSessionChannel) -> String {
        switch channel {
        case .snapshotFile: snapshot
        case .sessionUserInfo: session
        case .digestApplicationContext: digest
        }
    }
}

/// Full identity of one snapshot transfer. A version alone is insufficient:
/// cancelled and live transfers can carry the same snapshot version.
public struct SnapshotTransferIdentity: Sendable, Hashable {
    public let version: Int
    public let generation: Int

    public init(version: Int, generation: Int) {
        precondition(version >= 0)
        precondition(generation > 0)
        self.version = version
        self.generation = generation
    }
}

/// Property-list-safe metadata attached to a WCSession transfer.
public struct WCSessionTransferMetadata: Sendable, Equatable {
    public let kind: String
    public let sessionID: UUID?
    public let snapshot: SnapshotTransferIdentity?

    public init(kind: String, sessionID: UUID? = nil, snapshot: SnapshotTransferIdentity? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.snapshot = snapshot
    }
}

/// A Sendable snapshot of an NSError taken before crossing out of an
/// SDK-owned callback queue.
public struct WCSessionTransportError: Error, Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let description: String

    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }

    public init(_ error: any Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code, description: error.localizedDescription)
    }
}

public enum WCSessionActivation: Sendable, Equatable {
    case notActivated
    case inactive
    case activated
}

/// Result of inspecting opaque envelope bytes. The caller injects the
/// inspector (typically by adapting its envelope decoder), and this module
/// routes the result without interpreting the payload.
public enum OpaqueEnvelopeInspection: Sendable, Equatable {
    case accepted(kind: String)
    case heldNeedsAppUpdate(schemaVersion: Int)
    case malformed(reason: String)
}

public typealias OpaqueEnvelopeInspector = @Sendable (Data) -> OpaqueEnvelopeInspection

public enum WCSessionMalformedEnvelopeReason: Sendable, Equatable {
    case inspectorRejected(String)
    case unexpectedKind(expected: String, actual: String)
    case missingEnvelopeData
    case missingSessionIdentity
    case missingSnapshotIdentity
}

/// Facts delivered upward from the transport boundary. No case claims that a
/// peer applied or durably stored anything: finish callbacks remain transport
/// facts, and the protocol machines own acknowledgement semantics.
public enum WCSessionAdapterEvent: Sendable, Equatable {
    case activationStateChanged(WCSessionActivation)
    case activationCompleted(
        state: WCSessionActivation,
        alreadyQueuedSessionIDs: Set<UUID>,
        error: WCSessionTransportError?
    )
    case reachabilityChanged(Bool)
    case envelopeReceived(
        channel: WCSessionChannel,
        data: Data,
        metadata: WCSessionTransferMetadata
    )
    case envelopeHeld(
        channel: WCSessionChannel,
        data: Data,
        schemaVersion: Int,
        metadata: WCSessionTransferMetadata
    )
    case envelopeMalformed(
        channel: WCSessionChannel,
        data: Data?,
        reason: WCSessionMalformedEnvelopeReason,
        metadata: WCSessionTransferMetadata?
    )
    case sessionTransferFinished(
        id: UUID,
        reportedSuccess: Bool,
        error: WCSessionTransportError?
    )
    case snapshotTransferFinished(
        identity: SnapshotTransferIdentity,
        reportedSuccess: Bool,
        error: WCSessionTransportError?
    )
    case transportFailed(operation: WCSessionTransportOperation, error: WCSessionTransportError)
}

public enum WCSessionTransportOperation: Sendable, Equatable {
    case transmitSnapshot(SnapshotTransferIdentity)
    case publishDigest
}

/// The caller supplies an actor as the delivery boundary. This makes store
/// confinement explicit: adapter events cannot synchronously wander into a
/// ModelContext or any other caller-owned isolation domain.
public protocol WCSessionAdapterEventSink: Actor {
    func receive(_ event: WCSessionAdapterEvent) async
}

/// Watch-machine transport commands. Store-facing commands deliberately do
/// not appear here; applySnapshot/applyDigest remain executor responsibilities.
public enum WatchWCSessionCommand: Sendable, Equatable {
    case transmitSession(id: UUID, envelope: Data)
}

/// Phone-machine commands that actually have WCSession effects.
public enum PhoneWCSessionCommand: Sendable, Equatable {
    case transmitSnapshot(identity: SnapshotTransferIdentity, envelope: Data)
    case cancelSnapshotTransfer(identity: SnapshotTransferIdentity)
    case publishDigest(envelope: Data)
}

/// Cancellable handle returned by the file-transfer seam.
@MainActor
public protocol WCSessionFileTransferHandle: AnyObject {
    func cancel()
}

/// Fakeable subset of WCSession. WCSession itself is intentionally absent
/// from tests and from the adapter's public command surface.
@MainActor
public protocol WCSessionTransport: AnyObject {
    var delegate: (any WCSessionTransportDelegate)? { get set }
    var activationState: WCSessionActivation { get }
    var hasContentPending: Bool { get }
    var outstandingSessionIDs: Set<UUID> { get }

    func activate()
    func transferUserInfo(envelope: Data, metadata: WCSessionTransferMetadata)
    func updateApplicationContext(envelope: Data, metadata: WCSessionTransferMetadata) throws
    func transferFile(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws -> any WCSessionFileTransferHandle
}

/// Main-actor callbacks are the normalized side of the WCSession wrapper.
/// The concrete wrapper captures Sendable values on Apple's callback queue,
/// then hops here.
@MainActor
public protocol WCSessionTransportDelegate: AnyObject {
    func transportSessionStateDidChange(
        activationState: WCSessionActivation,
        hasContentPending: Bool
    )
    func transportActivationDidComplete(
        state: WCSessionActivation,
        hasContentPending: Bool,
        error: WCSessionTransportError?
    )
    func transportReachabilityDidChange(_ reachable: Bool)
    func transportDidReceive(
        channel: WCSessionChannel,
        data: Data,
        metadata: WCSessionTransferMetadata
    )
    func transportDidReceiveMalformed(
        channel: WCSessionChannel,
        reason: WCSessionMalformedEnvelopeReason,
        metadata: WCSessionTransferMetadata?
    )
    func transportSessionTransferDidFinish(
        id: UUID,
        error: WCSessionTransportError?
    )
    func transportSnapshotTransferDidFinish(
        identity: SnapshotTransferIdentity,
        error: WCSessionTransportError?
    )
}
