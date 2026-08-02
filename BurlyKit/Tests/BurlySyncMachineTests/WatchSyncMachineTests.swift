// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 watch-side rules, each pinned directly against the machine:
// outbox-until-ack (transfer callbacks are never delivery proof),
// activation retries, whole-replace snapshot monotonicity, and latest-wins
// digest application. Payloads are plain `String`s throughout — the machine
// runs the protocol without a single Burly type in sight, which is this
// module's seam (see Package.swift).
import Foundation
import Testing
import BurlySyncMachine

/// The machine over inert string payloads: identity and versions are the
/// machine's business; content is nobody's.
typealias TestWatchMachine = WatchSyncMachine<String, String, String>

@Suite("§5 watch machine — outbox")
struct WatchOutboxTests {
    @Test("a completed session enters the outbox and is transmitted immediately")
    func completionEntersOutboxAndTransmits() {
        var state = TestWatchMachine.State()
        let id = UUID()

        let commands = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)

        #expect(commands == [.transmitSession(id: id, payload: "s1")])
        #expect(state.outbox == [.init(id: id, payload: "s1")])
    }

    @Test("a replayed completion pins the first payload — one entry, one serialization, ever")
    func replayedCompletionPinsFirstPayload() {
        // m4-02 review 1, #1: replacing the outbox payload on replay made
        // the winner transport-order-dependent — the superseded bytes
        // were already on the wire at the same revision, so whichever
        // delivery arrived first stuck. Pinning the first serialization
        // makes it the only one that ever transmits.
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)

        let commands = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1'"), &state)

        #expect(state.outbox == [.init(id: id, payload: "s1")])
        #expect(commands == [.transmitSession(id: id, payload: "s1")])
    }

    @Test("activation retransmits every outbox entry in completion order")
    func activationRetransmitsInOrder() {
        var state = TestWatchMachine.State()
        let first = UUID()
        let second = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: first, payload: "a"), &state)
        _ = TestWatchMachine.handle(.sessionCompleted(id: second, payload: "b"), &state)

        let commands = TestWatchMachine.handle(.activated(alreadyQueuedSessionIDs: []), &state)

        #expect(commands == [
            .transmitSession(id: first, payload: "a"),
            .transmitSession(id: second, payload: "b")
        ])
    }

    @Test("activation skips entries the transport already has queued")
    func activationSkipsAlreadyQueued() {
        var state = TestWatchMachine.State()
        let queued = UUID()
        let waiting = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: queued, payload: "a"), &state)
        _ = TestWatchMachine.handle(.sessionCompleted(id: waiting, payload: "b"), &state)

        let commands = TestWatchMachine.handle(
            .activated(alreadyQueuedSessionIDs: [queued]),
            &state
        )

        #expect(commands == [.transmitSession(id: waiting, payload: "b")])
        // Skipping the enqueue is queue hygiene, not an ack: both stay put.
        #expect(state.outbox.map(\.id) == [queued, waiting])
    }

    @Test(
        "a transfer callback is never delivery proof — either outcome moves nothing",
        arguments: [true, false]
    )
    func transferCallbackIsNotDeliveryProof(reportedSuccess: Bool) {
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)
        let before = state

        let commands = TestWatchMachine.handle(
            .sessionTransferCallback(id: id, reportedSuccess: reportedSuccess),
            &state
        )

        #expect(commands.isEmpty)
        #expect(state == before)

        // And the session is still retried on the next activation — the
        // "successful" transfer bought it nothing.
        let retries = TestWatchMachine.handle(.activated(alreadyQueuedSessionIDs: []), &state)
        #expect(retries == [.transmitSession(id: id, payload: "s1")])
    }

    @Test("only an acked id leaves the outbox; unacked entries keep retrying")
    func onlyAckRemovesFromOutbox() {
        var state = TestWatchMachine.State()
        let acked = UUID()
        let unacked = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: acked, payload: "a"), &state)
        _ = TestWatchMachine.handle(.sessionCompleted(id: unacked, payload: "b"), &state)

        let commands = TestWatchMachine.handle(
            .digestReceived(ackedSessionIDs: [acked], payload: "d1"),
            &state
        )

        #expect(commands == [.applyDigest(payload: "d1")])
        #expect(state.outbox == [.init(id: unacked, payload: "b")])
    }

    @Test("acks for ids the outbox does not hold are harmless")
    func unknownAcksAreHarmless() {
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)

        let commands = TestWatchMachine.handle(
            .digestReceived(ackedSessionIDs: [UUID(), UUID()], payload: "d1"),
            &state
        )

        #expect(commands == [.applyDigest(payload: "d1")])
        #expect(state.outbox == [.init(id: id, payload: "s1")])
    }

    @Test("a completion for an already-acked id is refused as a stale resurrection — reported, never transmitted")
    func ackedIDCompletionIsRefused() {
        // m4-02 review 2, #1: the ack that prunes an entry also removes
        // its pin, so without this guard a later same-id completion
        // re-entered the outbox and handed the payload decision back to
        // transport order. The acked set the digest delivered refuses it.
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "A"), &state)
        _ = TestWatchMachine.handle(.digestReceived(ackedSessionIDs: [id], payload: "d1"), &state)
        #expect(state.outbox.isEmpty)

        let commands = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "B"), &state)

        #expect(commands == [.reportStaleSessionCompletion(id: id)])
        #expect(state.outbox.isEmpty)

        // Nothing to retry either — the refusal is total.
        let activation = TestWatchMachine.handle(.activated(alreadyQueuedSessionIDs: []), &state)
        #expect(activation.isEmpty)
    }

    @Test("the remembered acked set is replaced wholesale by each digest — the guard's horizon is the phone's retention")
    func ackedSetIsLatestWins() {
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "A"), &state)
        _ = TestWatchMachine.handle(.digestReceived(ackedSessionIDs: [id], payload: "d1"), &state)
        #expect(state.lastAckedSessionIDs == [id])

        // ~30 days later the phone's retention aged the id out of its
        // digests; the guard ages out with it, by design — bounded state
        // can refuse resurrections only within the ack horizon.
        _ = TestWatchMachine.handle(.digestReceived(ackedSessionIDs: [], payload: "d2"), &state)
        #expect(state.lastAckedSessionIDs.isEmpty)

        let commands = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "B"), &state)
        #expect(commands == [.transmitSession(id: id, payload: "B")])
    }
}

@Suite("§5 watch machine — digest application")
struct WatchDigestTests {
    @Test("every digest applies, acks or none — latest-wins has no filter")
    func digestAlwaysApplies() {
        var state = TestWatchMachine.State()

        let commands = TestWatchMachine.handle(
            .digestReceived(ackedSessionIDs: [], payload: "d-empty"),
            &state
        )

        #expect(commands == [.applyDigest(payload: "d-empty")])
    }

    @Test("re-delivery of the same digest re-applies and re-prunes idempotently")
    func digestRedeliveryConverges() {
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)

        let first = TestWatchMachine.handle(.digestReceived(ackedSessionIDs: [id], payload: "d1"), &state)
        let second = TestWatchMachine.handle(.digestReceived(ackedSessionIDs: [id], payload: "d1"), &state)

        // Same command both times — the store's applyDigest converges on
        // replay (its documented contract), and the outbox stays empty.
        #expect(first == [.applyDigest(payload: "d1")])
        #expect(second == [.applyDigest(payload: "d1")])
        #expect(state.outbox.isEmpty)
    }

    @Test("a content-empty digest with real acks prunes and applies — it is legitimate, not refused")
    func emptyContentDigestWithAcksIsLegitimate() {
        // Carried from m1-06 review round 4: the phone may have deleted the
        // only history behind these acks, so `lastPerformance: []` next to
        // real acked ids is an honest payload. The machine cannot even see
        // the emptiness — the payload is opaque by construction — so
        // refusal is structurally impossible; this pins that the acks act.
        var state = TestWatchMachine.State()
        let id = UUID()
        _ = TestWatchMachine.handle(.sessionCompleted(id: id, payload: "s1"), &state)

        let commands = TestWatchMachine.handle(
            .digestReceived(ackedSessionIDs: [id], payload: "d-no-entries"),
            &state
        )

        #expect(commands == [.applyDigest(payload: "d-no-entries")])
        #expect(state.outbox.isEmpty)

        // And after the phone's ack ages out (later digests no longer name
        // the id), nothing re-strands: no retransmission ever again.
        let laterDigest = TestWatchMachine.handle(
            .digestReceived(ackedSessionIDs: [], payload: "d-later"),
            &state
        )
        let activation = TestWatchMachine.handle(.activated(alreadyQueuedSessionIDs: []), &state)
        #expect(laterDigest == [.applyDigest(payload: "d-later")])
        #expect(activation.isEmpty)
        #expect(state.outbox.isEmpty)
    }
}

@Suite("§5 watch machine — snapshot monotonicity")
struct WatchSnapshotTests {
    @Test("a fresh install applies the first snapshot of any version, including 0")
    func freshInstallAppliesFirstSnapshot() {
        var state = TestWatchMachine.State()

        let commands = TestWatchMachine.handle(.snapshotReceived(version: 0, payload: "v0"), &state)

        #expect(commands == [.applySnapshot(version: 0, payload: "v0")])
        #expect(state.lastAppliedSnapshotVersion == 0)
    }

    @Test("a newer snapshot applies as a whole replace and advances the version line")
    func newerSnapshotApplies() {
        var state = TestWatchMachine.State(lastAppliedSnapshotVersion: 3)

        let commands = TestWatchMachine.handle(.snapshotReceived(version: 7, payload: "v7"), &state)

        #expect(commands == [.applySnapshot(version: 7, payload: "v7")])
        #expect(state.lastAppliedSnapshotVersion == 7)
    }

    @Test("equal and older snapshot versions are dropped — a replace never runs backwards", arguments: [7, 6, 0])
    func staleSnapshotsAreDropped(version: Int) {
        var state = TestWatchMachine.State(lastAppliedSnapshotVersion: 7)

        let commands = TestWatchMachine.handle(
            .snapshotReceived(version: version, payload: "stale"),
            &state
        )

        #expect(commands.isEmpty)
        #expect(state.lastAppliedSnapshotVersion == 7)
    }
}
