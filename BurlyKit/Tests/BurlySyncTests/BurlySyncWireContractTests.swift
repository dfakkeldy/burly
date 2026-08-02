// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BurlySync
import BurlyCore

@Suite("BurlySync wire DTOs and schema hold boundary")
struct BurlySyncWireContractTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("current-schema snapshot, session, and digest envelopes round-trip losslessly")
    func currentPayloadsRoundTrip() throws {
        let snapshot = BurlySyncEnvelope(payload: .snapshot(makeSnapshot()))
        let session = BurlySyncEnvelope(payload: .session(makeSessionPayload()))
        let digest = BurlySyncEnvelope(payload: .digest(makeDigest()))

        for envelope in [snapshot, session, digest] {
            let decoded = BurlySyncEnvelope.decode(try envelope.encodedData())
            #expect(decoded == .decoded(envelope))
        }
    }

    @Test("every newer-schema kind is held before an invalid payload can be decoded", arguments: ["snapshot", "session", "digest"])
    func newerSchemaIsHeldForEveryKind(kind: String) {
        // `payload` is deliberately the wrong type for every known kind. If
        // any current DTO decoder ran, the outcome would be malformed rather
        // than held, so this is a direct regression test for header-first
        // decoding.
        let json = """
        {"schemaVersion":\(BurlySync.currentSchemaVersion + 1),"kind":"\(kind)","payload":"not a \(kind) payload"}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(json) == .heldNeedsAppUpdate(version: BurlySync.currentSchemaVersion + 1))
    }

    @Test("a newer schema is held even when its kind is not understood")
    func newerUnknownKindIsHeld() {
        let json = """
        {"schemaVersion":\(BurlySync.currentSchemaVersion + 1),"kind":"aFutureKind","payload":{"anything":"at all"}}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(json) == .heldNeedsAppUpdate(version: BurlySync.currentSchemaVersion + 1))
    }

    @Test("an unknown current-schema kind is a typed malformed result")
    func currentUnknownKindIsMalformed() {
        let json = """
        {"schemaVersion":\(BurlySync.currentSchemaVersion),"kind":"other","payload":{}}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(json) == .malformed(.unknownKind("other")))
    }

    @Test("truncated JSON, missing schema version, and wrong envelope field types are malformed")
    func malformedEnvelopeInputsAreRejected() {
        let truncated = "{\"schemaVersion\":1,\"kind\":\"digest\",\"payload\":".data(using: .utf8)!
        let missingSchemaVersion = """
        {"kind":"digest","payload":{}}
        """.data(using: .utf8)!
        let wrongSchemaType = """
        {"schemaVersion":"one","kind":"digest","payload":{}}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(truncated) == .malformed(.invalidEnvelope))
        #expect(BurlySyncEnvelope.decode(missingSchemaVersion) == .malformed(.invalidEnvelope))
        #expect(BurlySyncEnvelope.decode(wrongSchemaType) == .malformed(.invalidEnvelope))
    }

    @Test("non-positive schema versions are rejected without payload decoding")
    func invalidSchemaVersionsAreRejected() {
        let negative = """
        {"schemaVersion":-1,"kind":"digest","payload":"not decoded"}
        """.data(using: .utf8)!
        let zero = """
        {"schemaVersion":0,"kind":"digest","payload":"not decoded"}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(negative) == .malformed(.invalidSchemaVersion(-1)))
        #expect(BurlySyncEnvelope.decode(zero) == .malformed(.invalidSchemaVersion(0)))
    }

    @Test("an absurd but representable newer schema version is held")
    func largestRepresentableSchemaVersionIsHeld() {
        let json = """
        {"schemaVersion":\(Int.max),"kind":"digest","payload":"not decoded"}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(json) == .heldNeedsAppUpdate(version: Int.max))
    }

    @Test("negative snapshot versions and flat hostile weights fail at their decode boundaries")
    func hostilePayloadValuesAreRejected() {
        let negativeSnapshot = """
        {"schemaVersion":1,"kind":"snapshot","payload":{"version":-1,"exercises":[],"routines":[]}}
        """.data(using: .utf8)!
        let negativeWeight = sessionJSON(weightKg: "-1")
        let nonFiniteWeight = sessionJSON(weightKg: "\"NaN\"")
        let positiveInfinityWeight = sessionJSON(weightKg: "\"Infinity\"")
        let nonConformingDecoder = JSONDecoder()
        nonConformingDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        #expect(BurlySyncEnvelope.decode(negativeSnapshot) == .malformed(.invalidPayload(.snapshot)))
        #expect(BurlySyncEnvelope.decode(negativeWeight) == .malformed(.invalidPayload(.session)))
        #expect(BurlySyncEnvelope.decode(nonFiniteWeight, using: nonConformingDecoder) == .malformed(.invalidPayload(.session)))
        #expect(BurlySyncEnvelope.decode(positiveInfinityWeight, using: nonConformingDecoder) == .malformed(.invalidPayload(.session)))
    }

    @Test("digest set snapshots do not adopt the domain isWarmup default (m4-01 review 2)")
    func digestSetSnapshotsRequireIsWarmup() {
        let exerciseID = UUID()
        let missingIsWarmup = """
        {
          "schemaVersion":1,
          "kind":"digest",
          "payload":{
            "snapshotVersion":3,
            "lastPerformance":[{
              "exerciseID":"\(exerciseID.uuidString)","performedAt":700000000,
              "sets":[{"weightKg":60,"reps":8}]
            }],
            "ackedSessionIDs":[]
          }
        }
        """.data(using: .utf8)!
        let complete = """
        {
          "schemaVersion":1,
          "kind":"digest",
          "payload":{
            "snapshotVersion":3,
            "lastPerformance":[{
              "exerciseID":"\(exerciseID.uuidString)","performedAt":700000000,
              "sets":[{"weightKg":60,"reps":8,"isWarmup":false}]
            }],
            "ackedSessionIDs":[]
          }
        }
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(missingIsWarmup) == .malformed(.invalidPayload(.digest)))

        let expected = BurlySyncEnvelope(payload: .digest(
            BurlyDigestPayloadDTO(
                snapshotVersion: 3,
                lastPerformance: [
                    ExerciseLastPerformanceData(
                        exerciseID: exerciseID,
                        performedAt: Date(timeIntervalSinceReferenceDate: 700000000),
                        sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8, isWarmup: false)]
                    )
                ],
                ackedSessionIDs: []
            )
        ))
        #expect(BurlySyncEnvelope.decode(complete) == .decoded(expected))
    }

    @Test("wire payloads do not adopt domain decoder defaults")
    func wirePayloadsRequireDefaultedDomainFields() {
        let snapshotMissingNeedsNaming = """
        {
          "schemaVersion":1,
          "kind":"snapshot",
          "payload":{
            "version":0,
            "exercises":[{
              "id":"\(UUID().uuidString)","name":"Bench Press","muscleGroups":["chest"],"origin":"curated"
            }],
            "routines":[]
          }
        }
        """.data(using: .utf8)!
        let sessionMissingState = """
        {
          "schemaVersion":1,
          "kind":"session",
          "payload":{
            "session":{
              "id":"\(UUID().uuidString)","startedAt":700000000,"revision":1,"origin":"live","items":[]
            },
            "needsNamingExercises":[]
          }
        }
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(snapshotMissingNeedsNaming) == .malformed(.invalidPayload(.snapshot)))
        #expect(BurlySyncEnvelope.decode(sessionMissingState) == .malformed(.invalidPayload(.session)))
    }

    @Test("session sets encode only flat canonical weightKg")
    func sessionSetWeightWireShapeIsFlat() throws {
        let data = try BurlySyncEnvelope(payload: .session(makeSessionPayload())).encodedData()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])
        let session = try #require(payload["session"] as? [String: Any])
        let items = try #require(session["items"] as? [[String: Any]])
        let sets = try #require(items.first?["sets"] as? [[String: Any]])
        let set = try #require(sets.first)

        #expect((set["weightKg"] as? Double) == 60)
        #expect(set["weight"] == nil)
    }

    @Test("unknown fields are tolerated at the envelope and payload layers")
    func unknownFieldsAreTolerated() {
        let json = """
        {
          "schemaVersion":1,
          "kind":"digest",
          "futureEnvelopeField":{"may":"ignore"},
          "payload":{
            "snapshotVersion":0,
            "lastPerformance":[],
            "ackedSessionIDs":[],
            "futurePayloadField":[1,2,3]
          }
        }
        """.data(using: .utf8)!

        let expected = BurlySyncEnvelope(payload: .digest(
            BurlyDigestPayloadDTO(snapshotVersion: 0, lastPerformance: [], ackedSessionIDs: [])
        ))
        #expect(BurlySyncEnvelope.decode(json) == .decoded(expected))
    }

    @Test("a large current-schema payload decodes without changing its contents")
    func largePayloadRoundTrips() throws {
        let exercises = (0 ..< 5_000).map { index in
            ExerciseData(
                id: UUID(),
                name: "Exercise \(index)",
                muscleGroups: [.chest],
                origin: .custom,
                needsNaming: false,
                archivedAt: nil
            )
        }
        let envelope = BurlySyncEnvelope(payload: .snapshot(
            BurlySnapshotPayloadDTO(version: 42, exercises: exercises, routines: [])
        ))

        #expect(BurlySyncEnvelope.decode(try envelope.encodedData()) == .decoded(envelope))
    }

    private func makeSnapshot() -> BurlySnapshotPayloadDTO {
        let exerciseID = UUID()
        return BurlySnapshotPayloadDTO(
            version: 42,
            exercises: [
                ExerciseData(
                    id: exerciseID,
                    name: "Bench Press",
                    muscleGroups: [.chest, .triceps],
                    origin: .curated,
                    needsNaming: false,
                    archivedAt: nil
                )
            ],
            routines: [
                RoutineData(
                    id: UUID(),
                    name: "Push",
                    orderIndex: 0,
                    items: [
                        RoutineItemData(
                            id: UUID(),
                            exerciseID: exerciseID,
                            order: 0,
                            defaultSetCount: 3,
                            restOverride: 120,
                            note: "Controlled reps"
                        )
                    ],
                    updatedAt: date,
                    archivedAt: nil
                )
            ]
        )
    }

    private func makeSessionPayload() -> BurlySessionPayloadDTO {
        let placeholderID = UUID()
        return BurlySessionPayloadDTO(
            session: SessionData(
                id: UUID(),
                routineID: UUID(),
                routineName: "Push",
                startedAt: date,
                endedAt: date.addingTimeInterval(1_800),
                state: .logged,
                revision: 2,
                healthKitWorkoutID: UUID(),
                origin: .live,
                items: [
                    SessionItemData(
                        id: UUID(),
                        exerciseID: placeholderID,
                        order: 0,
                        sets: [
                            SetRecordData(
                                id: UUID(),
                                order: 0,
                                weight: Weight(kg: 60),
                                reps: 8,
                                isWarmup: false,
                                completedAt: date.addingTimeInterval(60)
                            )
                        ]
                    )
                ],
                notes: "Good session"
            ),
            needsNamingExercises: [
                ExerciseData(
                    id: placeholderID,
                    name: "Custom exercise",
                    muscleGroups: [],
                    origin: .custom,
                    needsNaming: true
                )
            ]
        )
    }

    private func makeDigest() -> BurlyDigestPayloadDTO {
        BurlyDigestPayloadDTO(
            snapshotVersion: 42,
            lastPerformance: [
                ExerciseLastPerformanceData(
                    exerciseID: UUID(),
                    performedAt: date,
                    sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
                )
            ],
            ackedSessionIDs: [UUID()]
        )
    }

    private func sessionJSON(weightKg: String) -> Data {
        """
        {
          "schemaVersion":1,
          "kind":"session",
          "payload":{
            "session":{
              "id":"\(UUID().uuidString)","startedAt":700000000,"state":"logged","revision":1,
              "origin":"live","items":[{
                "id":"\(UUID().uuidString)","order":0,"sets":[{
                  "id":"\(UUID().uuidString)","order":0,"weightKg":\(weightKg),"reps":5,
                  "isWarmup":false,"completedAt":700000000
                }]
              }]
            },
            "needsNamingExercises":[]
          }
        }
        """.data(using: .utf8)!
    }
}
