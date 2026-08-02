// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySync — versioned envelope decoding

import Foundation

/// The payload discriminators frozen into Burly's sync JSON envelope.
public enum BurlySyncPayloadKind: String, Sendable, Equatable, Codable {
    case snapshot
    case session
    case digest
}

/// A typed payload which can be encoded in a `BurlySyncEnvelope`.
public enum BurlySyncPayload: Sendable, Equatable {
    case snapshot(BurlySnapshotPayloadDTO)
    case session(BurlySessionPayloadDTO)
    case digest(BurlyDigestPayloadDTO)

    public var kind: BurlySyncPayloadKind {
        switch self {
        case .snapshot: .snapshot
        case .session: .session
        case .digest: .digest
        }
    }
}

/// A complete wire envelope: `{ schemaVersion, kind, payload }`.
///
/// It is intentionally `Encodable`, rather than generally `Decodable`.
/// Decoding must go through `decode(_:using:)`, whose header-first policy
/// guarantees that a payload from a newer schema is held before its payload
/// is ever decoded into current DTOs.
public struct BurlySyncEnvelope: Sendable, Equatable, Encodable {
    public let schemaVersion: Int
    public let payload: BurlySyncPayload

    public var kind: BurlySyncPayloadKind { payload.kind }

    public init(schemaVersion: Int = BurlySync.currentSchemaVersion, payload: BurlySyncPayload) {
        precondition(schemaVersion > 0, "Schema version must be positive.")
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        switch payload {
        case let .snapshot(value):
            try container.encode(value, forKey: .payload)
        case let .session(value):
            try container.encode(value, forKey: .payload)
        case let .digest(value):
            try container.encode(value, forKey: .payload)
        }
    }

    /// Encodes the envelope using the supplied encoder (or Foundation's
    /// default `JSONEncoder`) without assigning any transport semantics.
    public func encodedData(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(self)
    }

    /// Decodes an envelope at the wire trust boundary.
    ///
    /// The schema header is decoded *before* `kind` or `payload`. Any schema
    /// above `BurlySync.currentSchemaVersion` is returned as `.heldNeedsAppUpdate`
    /// without trying to inspect or partially decode its payload. Callers can
    /// surface the app-update state and retain the original data for a later
    /// compatible receiver; applying, queueing, and retrying are deliberately
    /// outside this seam.
    public static func decode(
        _ data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) -> BurlySyncDecodeResult {
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            return .malformed(.invalidEnvelope)
        }

        guard header.schemaVersion > 0 else {
            return .malformed(.invalidSchemaVersion(header.schemaVersion))
        }
        guard header.schemaVersion <= BurlySync.currentSchemaVersion else {
            return .heldNeedsAppUpdate(version: header.schemaVersion)
        }
        guard header.schemaVersion == BurlySync.currentSchemaVersion else {
            return .malformed(.unsupportedSchemaVersion(header.schemaVersion))
        }

        let kindHeader: KindHeader
        do {
            kindHeader = try decoder.decode(KindHeader.self, from: data)
        } catch {
            return .malformed(.invalidEnvelope)
        }
        guard let kind = BurlySyncPayloadKind(rawValue: kindHeader.kind) else {
            return .malformed(.unknownKind(kindHeader.kind))
        }

        do {
            switch kind {
            case .snapshot:
                let envelope = try decoder.decode(TypedEnvelope<BurlySnapshotPayloadDTO>.self, from: data)
                return .decoded(BurlySyncEnvelope(schemaVersion: envelope.schemaVersion, payload: .snapshot(envelope.payload)))
            case .session:
                let envelope = try decoder.decode(TypedEnvelope<BurlySessionPayloadDTO>.self, from: data)
                return .decoded(BurlySyncEnvelope(schemaVersion: envelope.schemaVersion, payload: .session(envelope.payload)))
            case .digest:
                let envelope = try decoder.decode(TypedEnvelope<BurlyDigestPayloadDTO>.self, from: data)
                return .decoded(BurlySyncEnvelope(schemaVersion: envelope.schemaVersion, payload: .digest(envelope.payload)))
            }
        } catch {
            return .malformed(.invalidPayload(kind))
        }
    }

    /// Contains only the version on purpose. Synthesized decoding ignores
    /// `kind`, `payload`, and unknown future keys, so a held new-schema
    /// envelope cannot trigger any current payload decoder.
    private struct Header: Decodable {
        let schemaVersion: Int
    }

    private struct KindHeader: Decodable {
        let kind: String
    }

    private struct TypedEnvelope<Payload: Decodable>: Decodable {
        let schemaVersion: Int
        let kind: String
        let payload: Payload
    }
}

/// The only three outcomes at the sync JSON trust boundary.
public enum BurlySyncDecodeResult: Sendable, Equatable {
    case decoded(BurlySyncEnvelope)
    case heldNeedsAppUpdate(version: Int)
    case malformed(BurlySyncMalformedPayloadError)
}

/// A typed, non-throwing description of malformed wire input.
///
/// The original decoding error is deliberately not exposed: it is not a
/// stable wire API, while these cases are safe for UI/update-state handling
/// and tests to match.
public enum BurlySyncMalformedPayloadError: Sendable, Equatable {
    case invalidEnvelope
    case invalidSchemaVersion(Int)
    case unsupportedSchemaVersion(Int)
    case unknownKind(String)
    case invalidPayload(BurlySyncPayloadKind)
}
