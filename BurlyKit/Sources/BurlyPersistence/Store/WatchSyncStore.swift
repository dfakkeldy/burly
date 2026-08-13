// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import BurlyCore
import BurlySync

/// The persisted protocol facts owned by the watch coordinator.  The outbox
/// itself is the set of logged watch sessions; this journal remembers the
/// facts which cannot be reconstructed from that working set.
public struct WatchSyncStateData: Sendable, Equatable, Codable {
    /// Bump only when the persisted coordinator facts change incompatibly.
    /// An unknown version is rejected so an older build cannot erase a
    /// future snapshot watermark and re-admit stale replacement payloads.
    public var schemaVersion: Int
    public var lastAppliedSnapshotVersion: Int?
    public var lastAckedSessionIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastAppliedSnapshotVersion, lastAckedSessionIDs
    }

    public init(
        schemaVersion: Int = 1,
        lastAppliedSnapshotVersion: Int? = nil,
        lastAckedSessionIDs: Set<UUID> = []
    ) {
        self.schemaVersion = schemaVersion
        self.lastAppliedSnapshotVersion = lastAppliedSnapshotVersion
        self.lastAckedSessionIDs = lastAckedSessionIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard version == 0 || version == 1 else {
            throw WatchSyncStateDecodingError.unsupportedSchemaVersion(version)
        }
        self.init(
            schemaVersion: 1,
            lastAppliedSnapshotVersion: try container.decodeIfPresent(Int.self, forKey: .lastAppliedSnapshotVersion),
            lastAckedSessionIDs: try container.decodeIfPresent(Set<UUID>.self, forKey: .lastAckedSessionIDs) ?? []
        )
    }
}

public enum WatchSyncStateDecodingError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// Runtime-only operations for the watch endpoint.  `BurlyStore` remains the
/// public domain-store surface; this narrower protocol is the §5 executor
/// seam and is implemented only by the watch SwiftData store.
@MainActor
public protocol WatchSyncStore: AnyObject {
    func watchSyncState() throws -> WatchSyncStateData
    func loggedSessionsAwaitingAck() throws -> [SessionData]
    /// Returns false when `payload.version` is already applied locally.
    @discardableResult
    func replaceWatchWorkingSet(_ payload: BurlySnapshotPayloadDTO) throws -> Bool
    func applyWatchDigest(_ payload: BurlyDigestPayloadDTO) throws
    func watchOutboxPayload(sessionID: UUID) throws -> BurlySessionPayloadDTO?
}
