// SPDX-License-Identifier: GPL-3.0-or-later
// The digest's `routineLastPerformed` key is additive within schema 2 (see
// `BurlyDigestPayloadDTO`'s doc): no schema bump, older phones' digests
// still decode (with the key absent, not empty), and each entry is strict
// once present.
import Foundation
import Testing
@testable import BurlySync
import BurlyCore

@Suite("Digest routine dates — additive within schema 2")
struct DigestRoutineDatesWireTests {
    private let routineID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test("routine dates ride schema 2: no bump, so older watches keep reading digests")
    func noSchemaBump() throws {
        #expect(BurlySync.currentSchemaVersion == 2)
        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 4,
            lastPerformance: [],
            ackedSessionIDs: [],
            routineLastPerformed: [BurlyRoutineLastPerformedDTO(routineID: routineID, performedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))]
        )
        let envelope = BurlySyncEnvelope(payload: .digest(payload))
        #expect(envelope.schemaVersion == 2)
        #expect(BurlySyncEnvelope.decode(try envelope.encodedData()) == .decoded(envelope))

        let object = try #require(try JSONSerialization.jsonObject(with: try envelope.encodedData()) as? [String: Any])
        let body = try #require(object["payload"] as? [String: Any])
        let expectedKeys: Set<String> = ["snapshotVersion", "lastPerformance", "ackedSessionIDs", "routineLastPerformed"]
        #expect(Set(body.keys) == expectedKeys)
    }

    @Test("a digest from a phone that predates routine dates keeps the key absent, distinct from an empty list")
    func absentKeyStaysAbsent() throws {
        let json = Data(#"{"schemaVersion":2,"kind":"digest","payload":{"snapshotVersion":3,"lastPerformance":[],"ackedSessionIDs":[]}}"#.utf8)
        let expected = BurlySyncEnvelope(schemaVersion: 2, payload: .digest(
            BurlyDigestPayloadDTO(snapshotVersion: 3, lastPerformance: [], ackedSessionIDs: [])
        ))
        #expect(BurlySyncEnvelope.decode(json) == .decoded(expected))
        guard case let .decoded(envelope) = BurlySyncEnvelope.decode(json),
              case let .digest(payload) = envelope.payload else {
            Issue.record("expected a decoded digest")
            return
        }
        #expect(payload.routineLastPerformed == nil)

        // And an absent list is encoded absent, so it round-trips as such.
        let reencoded = try BurlySyncEnvelope(payload: .digest(payload)).encodedData()
        let object = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let body = try #require(object["payload"] as? [String: Any])
        #expect(body["routineLastPerformed"] == nil)

        let empty = BurlyDigestPayloadDTO(snapshotVersion: 3, lastPerformance: [], ackedSessionIDs: [], routineLastPerformed: [])
        #expect(BurlySyncEnvelope.decode(try BurlySyncEnvelope(payload: .digest(empty)).encodedData())
            == .decoded(BurlySyncEnvelope(payload: .digest(empty))))
        #expect(empty != BurlyDigestPayloadDTO(snapshotVersion: 3, lastPerformance: [], ackedSessionIDs: []))
    }

    @Test("a present routine entry requires both fields")
    func entriesAreStrict() {
        let missingDate = Data("""
        {"schemaVersion":2,"kind":"digest","payload":{"snapshotVersion":3,"lastPerformance":[],"ackedSessionIDs":[],
         "routineLastPerformed":[{"routineID":"\(routineID.uuidString)"}]}}
        """.utf8)
        #expect(BurlySyncEnvelope.decode(missingDate) == .malformed(.invalidPayload(.digest)))

        let wellFormed = Data("""
        {"schemaVersion":2,"kind":"digest","payload":{"snapshotVersion":3,"lastPerformance":[],"ackedSessionIDs":[],
         "routineLastPerformed":[{"routineID":"\(routineID.uuidString)","performedAt":800000000}]}}
        """.utf8)
        let expected = BurlySyncEnvelope(schemaVersion: 2, payload: .digest(BurlyDigestPayloadDTO(
            snapshotVersion: 3,
            lastPerformance: [],
            ackedSessionIDs: [],
            routineLastPerformed: [BurlyRoutineLastPerformedDTO(routineID: routineID, performedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))]
        )))
        #expect(BurlySyncEnvelope.decode(wellFormed) == .decoded(expected))
    }
}
