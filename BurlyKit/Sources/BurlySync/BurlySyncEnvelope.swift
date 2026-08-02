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
    ///
    /// Additive schema evolution adds a version case and its translation below;
    /// never replace an older version's decoder with the hold path.
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
        switch header.schemaVersion {
        case 1:
            return decodeVersion1(data, using: decoder)
        default:
            return .malformed(.unsupportedOlderSchemaVersion(header.schemaVersion))
        }
    }

    /// Contains only the version on purpose. Synthesized decoding ignores
    /// `kind`, `payload`, and unknown future keys, so a held new-schema
    /// envelope cannot trigger any current payload decoder.
    private struct Header: Decodable {
        let schemaVersion: Int
    }

    /// Decodes all version-1 details in the second and final JSON pass. The
    /// header-only first pass is intentionally the only work done for held
    /// future versions.
    private static func decodeVersion1(
        _ data: Data,
        using decoder: JSONDecoder
    ) -> BurlySyncDecodeResult {
        do {
            let envelope = try decoder.decode(Version1Envelope.self, from: data)
            return .decoded(
                BurlySyncEnvelope(
                    schemaVersion: envelope.schemaVersion,
                    payload: envelope.payload
                )
            )
        } catch let error as Version1DecodingError {
            switch error {
            case let .unknownKind(rawValue):
                return .malformed(.unknownKind(rawValue))
            case let .invalidPayload(kind):
                return .malformed(.invalidPayload(kind))
            }
        } catch {
            return .malformed(.invalidEnvelope)
        }
    }

    private struct Version1Envelope: Decodable {
        let schemaVersion: Int
        let payload: BurlySyncPayload

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, kind, payload
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            let rawKind = try container.decode(String.self, forKey: .kind)
            guard let kind = BurlySyncPayloadKind(rawValue: rawKind) else {
                throw Version1DecodingError.unknownKind(rawKind)
            }

            do {
                switch kind {
                case .snapshot:
                    payload = .snapshot(try container.decode(BurlySnapshotPayloadDTO.self, forKey: .payload))
                case .session:
                    payload = .session(try container.decode(BurlySessionPayloadDTO.self, forKey: .payload))
                case .digest:
                    payload = .digest(try container.decode(BurlyDigestPayloadDTO.self, forKey: .payload))
                }
            } catch {
                throw Version1DecodingError.invalidPayload(kind)
            }
        }
    }

    private enum Version1DecodingError: Error {
        case unknownKind(String)
        case invalidPayload(BurlySyncPayloadKind)
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
    case unsupportedOlderSchemaVersion(Int)
    case unknownKind(String)
    case invalidPayload(BurlySyncPayloadKind)
}
