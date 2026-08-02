// SPDX-License-Identifier: GPL-3.0-or-later
// Concrete watch endpoint: envelope routing plus the atomic store executor.

import Foundation
import BurlyPersistence
import BurlySync

@MainActor
public final class WatchSyncCoordinator {
    public enum ReceiveOutcome: Sendable, Equatable {
        case appliedSnapshot(version: Int)
        case appliedDigest
        case heldNeedsAppUpdate(version: Int)
        case malformed
        case ignoredWrongDirection
        case ignoredStaleSnapshot
    }

    private let store: any WatchSyncStore
    private var state: BurlyWatchSyncMachine.State

    public init(store: any WatchSyncStore) throws {
        self.store = store
        let durable = try store.watchSyncState()
        let outbox = try store.loggedSessionsAwaitingAck().compactMap { session in
            try store.watchOutboxPayload(sessionID: session.id).map {
                BurlyWatchSyncMachine.OutboxEntry(id: session.id, payload: $0)
            }
        }
        state = BurlyWatchSyncMachine.State(
            outbox: outbox,
            lastAppliedSnapshotVersion: durable.lastAppliedSnapshotVersion,
            lastAckedSessionIDs: durable.lastAckedSessionIDs
        )
    }

    /// Called after Finish has durably stored the logged session. The session
    /// store itself is the durable outbox; payload construction embeds every
    /// referenced `needsNaming` exercise before it is encoded.
    public func completedSession(id: UUID) throws -> [Data] {
        guard let payload = try store.watchOutboxPayload(sessionID: id) else { return [] }
        return try execute(BurlyWatchSyncMachine.handle(.sessionCompleted(payload), &state))
    }

    /// Retry is activation-driven; transport completion is intentionally not
    /// a call site here because it is not delivery proof.
    public func activated(alreadyQueuedSessionIDs: Set<UUID> = []) throws -> [Data] {
        try execute(BurlyWatchSyncMachine.handle(.activated(alreadyQueuedSessionIDs: alreadyQueuedSessionIDs), &state))
    }

    @discardableResult
    public func receive(_ data: Data) throws -> ReceiveOutcome {
        switch BurlySyncEnvelope.decode(data) {
        case let .heldNeedsAppUpdate(version):
            return .heldNeedsAppUpdate(version: version)
        case .malformed:
            return .malformed
        case let .decoded(envelope):
            var candidate = state
            switch envelope.payload {
            case let .snapshot(payload):
                let commands = BurlyWatchSyncMachine.handle(.snapshotReceived(payload), &candidate)
                guard !commands.isEmpty else { return .ignoredStaleSnapshot }
                // Store method persists the version with its replacement.
                try store.replaceWatchWorkingSet(payload)
                state = candidate
                return .appliedSnapshot(version: payload.version)
            case let .digest(payload):
                _ = BurlyWatchSyncMachine.handle(.digestReceived(payload), &candidate)
                // This is the only production digest route. It stages last
                // performance, pruning, and `lastAckedSessionIDs` together.
                try store.applyWatchDigest(payload)
                state = candidate
                return .appliedDigest
            case .session:
                return .ignoredWrongDirection
            }
        }
    }

    private func execute(_ commands: [BurlyWatchSyncMachine.Command]) throws -> [Data] {
        try commands.compactMap { command in
            switch command {
            case let .transmitSession(_, payload):
                return try BurlySyncEnvelope(payload: .session(payload)).encodedData()
            case .applySnapshot, .applyDigest, .reportStaleSessionCompletion:
                return nil
            }
        }
    }
}
