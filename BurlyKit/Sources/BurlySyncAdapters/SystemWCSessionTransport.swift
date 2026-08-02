// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — concrete Apple WatchConnectivity bridge

#if os(iOS) || os(watchOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
private final class SystemWCSessionFileTransferHandle: WCSessionFileTransferHandle {
    private let transfer: WCSessionFileTransfer

    init(_ transfer: WCSessionFileTransfer) {
        self.transfer = transfer
    }

    func cancel() {
        transfer.cancel()
    }
}

/// WCSession wrapper used by the phone and watch composition roots. Apple
/// delegate/KVO callbacks first snapshot Sendable values, then explicitly hop
/// to MainActor; no SDK-owned queue is assumed to satisfy actor isolation.
@MainActor
public final class SystemWCSessionTransport: NSObject, WCSessionTransport {
    public weak var delegate: (any WCSessionTransportDelegate)?

    private let session: WCSession
    private var activationObservation: NSKeyValueObservation?
    private var contentPendingObservation: NSKeyValueObservation?

    public init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    public var activationState: WCSessionActivation {
        Self.activation(from: session.activationState.rawValue)
    }

    public var hasContentPending: Bool { session.hasContentPending }

    public var outstandingSessionIDs: Set<UUID> {
        Set(session.outstandingUserInfoTransfers.compactMap {
            Self.metadata(from: $0.userInfo)?.sessionID
        })
    }

    public func activate() {
        session.delegate = self
        installObservationsIfNeeded()
        session.activate()
    }

    public func transferUserInfo(envelope: Data, metadata: WCSessionTransferMetadata) {
        session.transferUserInfo(Self.payload(envelope: envelope, metadata: metadata))
    }

    public func updateApplicationContext(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws {
        try session.updateApplicationContext(Self.payload(envelope: envelope, metadata: metadata))
    }

    public func transferFile(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws -> any WCSessionFileTransferHandle {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-envelope-\(UUID().uuidString)")
            .appendingPathExtension("data")
        try envelope.write(to: fileURL, options: .atomic)
        let transfer = session.transferFile(fileURL, metadata: Self.metadataDictionary(metadata))
        return SystemWCSessionFileTransferHandle(transfer)
    }

    private func installObservationsIfNeeded() {
        guard activationObservation == nil, contentPendingObservation == nil else { return }

        activationObservation = session.observe(
            \.activationState,
            options: [.initial, .new]
        ) { @Sendable [weak self] observedSession, change in
            guard let rawValue = change.newValue?.rawValue else { return }
            let state = Self.activation(from: rawValue)
            let hasContentPending = observedSession.hasContentPending
            Task { @MainActor [weak self] in
                self?.delegate?.transportSessionStateDidChange(
                    activationState: state,
                    hasContentPending: hasContentPending
                )
            }
        }

        contentPendingObservation = session.observe(
            \.hasContentPending,
            options: [.initial, .new]
        ) { @Sendable [weak self] observedSession, change in
            guard let hasContentPending = change.newValue else { return }
            let state = Self.activation(from: observedSession.activationState.rawValue)
            Task { @MainActor [weak self] in
                self?.delegate?.transportSessionStateDidChange(
                    activationState: state,
                    hasContentPending: hasContentPending
                )
            }
        }
    }

    nonisolated private static func activation(from rawValue: Int) -> WCSessionActivation {
        switch rawValue {
        case WCSessionActivationState.inactive.rawValue: .inactive
        case WCSessionActivationState.activated.rawValue: .activated
        default: .notActivated
        }
    }

    nonisolated private static func payload(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) -> [String: Any] {
        var result = metadataDictionary(metadata)
        result[Keys.envelope] = envelope
        return result
    }

    nonisolated private static func metadataDictionary(
        _ metadata: WCSessionTransferMetadata
    ) -> [String: Any] {
        var result: [String: Any] = [Keys.kind: metadata.kind]
        if let sessionID = metadata.sessionID {
            result[Keys.sessionID] = sessionID.uuidString
        }
        if let snapshot = metadata.snapshot {
            result[Keys.snapshotVersion] = snapshot.version
            result[Keys.snapshotGeneration] = snapshot.generation
        }
        return result
    }

    nonisolated private static func metadata(
        from dictionary: [String: Any]
    ) -> WCSessionTransferMetadata? {
        guard let kind = dictionary[Keys.kind] as? String else { return nil }
        let sessionID = (dictionary[Keys.sessionID] as? String).flatMap(UUID.init(uuidString:))

        let snapshot: SnapshotTransferIdentity?
        if let version = dictionary[Keys.snapshotVersion] as? Int,
           let generation = dictionary[Keys.snapshotGeneration] as? Int,
           version >= 0,
           generation > 0 {
            snapshot = SnapshotTransferIdentity(version: version, generation: generation)
        } else {
            snapshot = nil
        }
        return WCSessionTransferMetadata(kind: kind, sessionID: sessionID, snapshot: snapshot)
    }

    nonisolated private static func received(
        channel: WCSessionChannel,
        dictionary: [String: Any]
    ) -> (Data, WCSessionTransferMetadata)? {
        guard let data = dictionary[Keys.envelope] as? Data,
              let metadata = metadata(from: dictionary)
        else { return nil }
        return (data, metadata)
    }

    private enum Keys {
        static let envelope = "syncEnvelope"
        static let kind = "syncKind"
        static let sessionID = "sessionID"
        static let snapshotVersion = "snapshotVersion"
        static let snapshotGeneration = "snapshotGeneration"
    }
}

extension SystemWCSessionTransport: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let state = Self.activation(from: activationState.rawValue)
        let hasContentPending = session.hasContentPending
        let transportError = error.map(WCSessionTransportError.init)
        Task { @MainActor [weak self] in
            self?.delegate?.transportActivationDidComplete(
                state: state,
                hasContentPending: hasContentPending,
                error: transportError
            )
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.delegate?.transportReachabilityDidChange(reachable)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        receive(dictionary: applicationContext, channel: .digestApplicationContext)
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(dictionary: userInfo, channel: .sessionUserInfo)
    }

    nonisolated public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata.flatMap(Self.metadata(from:))
        let data = try? Data(contentsOf: file.fileURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data, let metadata else {
                self.delegate?.transportDidReceiveMalformed(
                    channel: .snapshotFile,
                    reason: data == nil ? .missingEnvelopeData : .missingSnapshotIdentity,
                    metadata: metadata
                )
                return
            }
            self.delegate?.transportDidReceive(
                channel: .snapshotFile,
                data: data,
                metadata: metadata
            )
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        let sessionID = Self.metadata(from: userInfoTransfer.userInfo)?.sessionID
        let transportError = error.map(WCSessionTransportError.init)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let sessionID else {
                self.delegate?.transportDidReceiveMalformed(
                    channel: .sessionUserInfo,
                    reason: .missingSessionIdentity,
                    metadata: nil
                )
                return
            }
            self.delegate?.transportSessionTransferDidFinish(id: sessionID, error: transportError)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let metadata = fileTransfer.file.metadata.flatMap(Self.metadata(from:))
        let sourceURL = fileTransfer.file.fileURL
        try? FileManager.default.removeItem(at: sourceURL)
        let transportError = error.map(WCSessionTransportError.init)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let identity = metadata?.snapshot else {
                self.delegate?.transportDidReceiveMalformed(
                    channel: .snapshotFile,
                    reason: .missingSnapshotIdentity,
                    metadata: metadata
                )
                return
            }
            self.delegate?.transportSnapshotTransferDidFinish(
                identity: identity,
                error: transportError
            )
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
        let hasContentPending = session.hasContentPending
        Task { @MainActor [weak self] in
            self?.delegate?.transportSessionStateDidChange(
                activationState: .inactive,
                hasContentPending: hasContentPending
            )
        }
    }

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        let hasContentPending = session.hasContentPending
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.transportSessionStateDidChange(
                activationState: .notActivated,
                hasContentPending: hasContentPending
            )
            self.session.activate()
        }
    }
    #endif

    nonisolated private func receive(
        dictionary: [String: Any],
        channel: WCSessionChannel
    ) {
        let received = Self.received(channel: channel, dictionary: dictionary)
        let metadata = Self.metadata(from: dictionary)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (data, metadata) = received else {
                self.delegate?.transportDidReceiveMalformed(
                    channel: channel,
                    reason: .missingEnvelopeData,
                    metadata: metadata
                )
                return
            }
            self.delegate?.transportDidReceive(channel: channel, data: data, metadata: metadata)
        }
    }
}
#endif
