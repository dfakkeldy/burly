// SPDX-License-Identifier: GPL-3.0-or-later
// The machine ⇄ wire binding: adapters must extract exactly the identity
// facts the machines decide on (id, revision, version, acked ids) and pass
// the DTO through untouched — plus the DTO-level flavor of the carried
// m1-06 rule that an entry-less digest with real acks is legitimate all the
// way down to the store-facing receipt.
import Foundation
import Testing
@testable import BurlySync
import BurlySyncMachine
import BurlyCore

@Suite("BurlySync machine binding")
struct SyncMachineBindingTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the watch session event carries the session's id and the DTO verbatim")
    func watchSessionEventExtractsIdentity() {
        let payload = makeSessionPayload(revision: 1)

        let event = BurlyWatchSyncMachine.Event.sessionCompleted(payload)

        #expect(event == .sessionCompleted(id: payload.session.id, payload: payload))
    }

    @Test("the watch snapshot event carries the payload's monotonic version")
    func watchSnapshotEventExtractsVersion() {
        let payload = BurlySnapshotPayloadDTO(version: 42, exercises: [], routines: [])

        let event = BurlyWatchSyncMachine.Event.snapshotReceived(payload)

        #expect(event == .snapshotReceived(version: 42, payload: payload))
    }

    @Test("the watch digest event carries the acked ids as a set, duplicates collapsed")
    func watchDigestEventExtractsAcks() {
        let acked = UUID()
        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 3,
            lastPerformance: [],
            ackedSessionIDs: [acked, acked]
        )

        let event = BurlyWatchSyncMachine.Event.digestReceived(payload)

        #expect(event == .digestReceived(ackedSessionIDs: [acked], payload: payload))
    }

    @Test("the phone session event carries the DTO's revision and the caller's stored revision")
    func phoneSessionEventExtractsRevisions() {
        let payload = makeSessionPayload(revision: 4)

        let event = BurlyPhoneSyncMachine.Event.sessionReceived(payload, storedRevision: 2)

        #expect(event == .sessionReceived(
            id: payload.session.id,
            revision: 4,
            storedRevision: 2,
            payload: payload
        ))
    }

    @Test("a publish-digest command's unordered ack set becomes a deterministic wire array")
    func digestBuilderSortsAcks() throws {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]

        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 7,
            lastPerformance: [],
            ackedSessionIDs: ids
        )

        #expect(Set(payload.ackedSessionIDs) == ids)
        #expect(payload.ackedSessionIDs.map(\.uuidString) == ids.map(\.uuidString).sorted())

        // Same set in, same bytes out — the digest a retry re-encodes is
        // byte-identical to the one it repeats.
        let again = BurlyDigestPayloadDTO(
            snapshotVersion: 7,
            lastPerformance: [],
            ackedSessionIDs: ids
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(payload) == encoder.encode(again))
    }

    @Test("an entry-less digest with real acks flows DTO → machine → receipt without loss")
    func entrylessDigestFlowsToReceipt() {
        // Carried m1-06 review 4, DTO-level: the phone deleted its history
        // but still acks — every layer must pass both halves through.
        let acked = UUID()
        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 5,
            lastPerformance: [],
            ackedSessionIDs: [acked]
        )
        var state = BurlyWatchSyncMachine.State(
            outbox: [.init(id: acked, payload: makeSessionPayload(revision: 1, id: acked))]
        )

        let commands = BurlyWatchSyncMachine.handle(.digestReceived(payload), &state)

        // The outbox pruned and the apply command carries the DTO whole…
        #expect(state.outbox.isEmpty)
        #expect(commands == [.applyDigest(payload: payload)])

        // …and the store-facing receipt keeps both halves, exactly as
        // `SessionDigestApplying` will consume them.
        let receipt = SessionDigestReceipt(applying: payload)
        #expect(receipt.lastPerformance.isEmpty)
        #expect(receipt.ackedSessionIDs == [acked])
    }

    @Test("the receipt bridge copies both digest halves verbatim")
    func receiptBridgeCopiesBothHalves() {
        let entry = ExerciseLastPerformanceData(
            exerciseID: UUID(),
            performedAt: date,
            sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
        )
        let acked = UUID()
        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 9,
            lastPerformance: [entry],
            ackedSessionIDs: [acked]
        )

        let receipt = SessionDigestReceipt(applying: payload)

        #expect(receipt.lastPerformance == [entry])
        #expect(receipt.ackedSessionIDs == [acked])
    }

    private func makeSessionPayload(revision: Int, id: UUID = UUID()) -> BurlySessionPayloadDTO {
        BurlySessionPayloadDTO(
            session: SessionData(
                id: id,
                startedAt: date,
                endedAt: date.addingTimeInterval(1_800),
                state: .logged,
                revision: revision,
                origin: .live,
                items: []
            ),
            needsNamingExercises: []
        )
    }
}
