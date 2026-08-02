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

    @Test("truncated JSON and wrong envelope field types are malformed")
    func malformedEnvelopeInputsAreRejected() {
        let truncated = "{\"schemaVersion\":1,\"kind\":\"digest\",\"payload\":".data(using: .utf8)!
        let wrongSchemaType = """
        {"schemaVersion":"one","kind":"digest","payload":{}}
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(truncated) == .malformed(.invalidEnvelope))
        #expect(BurlySyncEnvelope.decode(wrongSchemaType) == .malformed(.invalidEnvelope))
    }

    @Test("non-positive and older schema versions are rejected without payload decoding")
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

    @Test("negative snapshot versions and hostile non-finite weights fail at their decode boundaries")
    func hostilePayloadValuesAreRejected() {
        let negativeSnapshot = """
        {"schemaVersion":1,"kind":"snapshot","payload":{"version":-1,"exercises":[],"routines":[]}}
        """.data(using: .utf8)!
        let unrepresentableWeight = """
        {
          "schemaVersion":1,
          "kind":"session",
          "payload":{
            "session":{
              "id":"\(UUID().uuidString)","startedAt":700000000,"state":"logged","revision":1,
              "origin":"live","items":[{
                "id":"\(UUID().uuidString)","order":0,"sets":[{
                  "id":"\(UUID().uuidString)","order":0,"weight":{"kg":1e400},"reps":5,
                  "isWarmup":false,"completedAt":700000000
                }]
              }]
            },
            "needsNamingExercises":[]
          }
        }
        """.data(using: .utf8)!

        #expect(BurlySyncEnvelope.decode(negativeSnapshot) == .malformed(.invalidPayload(.snapshot)))
        #expect(BurlySyncEnvelope.decode(unrepresentableWeight) == .malformed(.invalidPayload(.session)))
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
            BurlyExerciseDTO(
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
                BurlyExerciseDTO(
                    id: exerciseID,
                    name: "Bench Press",
                    muscleGroups: [.chest, .triceps],
                    origin: .curated,
                    needsNaming: false,
                    archivedAt: nil
                )
            ],
            routines: [
                BurlyRoutineDTO(
                    id: UUID(),
                    name: "Push",
                    orderIndex: 0,
                    items: [
                        BurlyRoutineItemDTO(
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
            session: BurlySessionDTO(
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
                    BurlySessionItemDTO(
                        id: UUID(),
                        exerciseID: placeholderID,
                        order: 0,
                        sets: [
                            BurlySetDTO(
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
            needsNamingExercises: [BurlyNeedsNamingExerciseDTO(id: placeholderID)]
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
}
