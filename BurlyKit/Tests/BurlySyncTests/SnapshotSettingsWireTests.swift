// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BurlySync
import BurlyCore

/// Schema 2 adds the phone's display unit and global rest default to the
/// snapshot. These pin the per-version rule: schema 1 implies kg and 90 s,
/// schema 2 requires both keys, and the rest default lands on §3's grid.
@Suite("Snapshot settings (schema 2)")
struct SnapshotSettingsWireTests {
    @Test("the current schema is 2")
    func currentSchemaIsTwo() {
        #expect(BurlySync.currentSchemaVersion == 2)
    }

    @Test("a schema-2 snapshot round-trips its unit and rest default")
    func schemaTwoRoundTrips() throws {
        let envelope = BurlySyncEnvelope(payload: .snapshot(
            BurlySnapshotPayloadDTO(
                version: 4,
                exercises: [],
                routines: [],
                displayUnit: .pounds,
                restDefault: 120
            )
        ))
        let data = try envelope.encodedData()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])

        #expect(root["schemaVersion"] as? Int == 2)
        #expect(payload["displayUnit"] as? String == "lb")
        #expect(payload["restDefault"] as? Double == 120)
        #expect(BurlySyncEnvelope.decode(data) == .decoded(envelope))
    }

    @Test("a schema-1 snapshot decodes as kilograms and the §3 90 s default")
    func schemaOneImpliesDefaults() {
        let json = snapshotJSON(schemaVersion: 1, settings: "")

        guard case let .decoded(envelope) = BurlySyncEnvelope.decode(json),
              case let .snapshot(payload) = envelope.payload
        else {
            Issue.record("schema-1 snapshot did not decode")
            return
        }
        #expect(envelope.schemaVersion == 1)
        #expect(payload.displayUnit == .kilograms)
        #expect(payload.restDefault == RestDuration.globalDefault)
    }

    @Test("a schema-2 snapshot missing either setting is malformed", arguments: [
        #""displayUnit":"lb","#,
        #""restDefault":120,"#,
        ""
    ])
    func schemaTwoRequiresBothSettings(settings: String) {
        let json = snapshotJSON(schemaVersion: 2, settings: settings)
        #expect(BurlySyncEnvelope.decode(json) == .malformed(.invalidPayload(.snapshot)))
    }

    @Test("an unknown display unit is malformed, not silently kilograms")
    func unknownUnitIsMalformed() {
        let json = snapshotJSON(schemaVersion: 2, settings: #""displayUnit":"stone","restDefault":90,"#)
        #expect(BurlySyncEnvelope.decode(json) == .malformed(.invalidPayload(.snapshot)))
    }

    @Test("an off-grid or out-of-range rest default is clamped onto the §3 grid", arguments: [
        (100.0, 105.0),
        (5.0, 15.0),
        (900.0, 300.0)
    ])
    func restDefaultIsClamped(raw: Double, expected: Double) {
        let json = snapshotJSON(schemaVersion: 2, settings: #""displayUnit":"kg","restDefault":\#(raw),"#)

        guard case let .decoded(envelope) = BurlySyncEnvelope.decode(json),
              case let .snapshot(payload) = envelope.payload
        else {
            Issue.record("snapshot did not decode")
            return
        }
        #expect(payload.restDefault == expected)
        #expect(BurlySnapshotPayloadDTO(version: 0, exercises: [], routines: [], restDefault: raw).restDefault == expected)
    }

    @Test("a schema-2 session and digest decode unchanged")
    func otherKindsAreUnchangedInSchemaTwo() {
        let digest = """
        {"schemaVersion":2,"kind":"digest","payload":{"snapshotVersion":1,"lastPerformance":[],"ackedSessionIDs":[]}}
        """.data(using: .utf8)!
        let expected = BurlySyncEnvelope(payload: .digest(
            BurlyDigestPayloadDTO(snapshotVersion: 1, lastPerformance: [], ackedSessionIDs: [])
        ))
        #expect(BurlySyncEnvelope.decode(digest) == .decoded(expected))
    }

    private func snapshotJSON(schemaVersion: Int, settings: String) -> Data {
        """
        {"schemaVersion":\(schemaVersion),"kind":"snapshot","payload":{\(settings)"version":3,"exercises":[],"routines":[]}}
        """.data(using: .utf8)!
    }
}
