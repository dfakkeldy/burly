// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 phone-side rules, each pinned directly against the machine:
// the idempotent upsert rule (incoming revision ≤ stored → drop silently)
// as a pure routing decision, acks earned exclusively by store
// confirmation (m4-02 review 1, #4), the 30-day bounded ack retention as
// forward-only accumulated age (review #2), digest regeneration triggers,
// and the snapshot version line with supersession and wedge-proof push
// recovery (review #3).
import Foundation
import Testing
import BurlySyncMachine

typealias TestPhoneMachine = PhoneSyncMachine<String>

/// A fixed origin so every test advances time explicitly — there is no
/// `Date()` anywhere in these tests or in the machine they drive.
private let t0 = Date(timeIntervalSinceReferenceDate: 0)

@Suite("§5 phone machine — session ingest routes; the store confirms")
struct PhoneIngestTests {
    let machine = TestPhoneMachine()

    @Test("an unstored session routes to the conditional upsert — no ack, no publish yet")
    func newSessionRoutesToUpsert() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )

        // The command carries the revision so the store transaction can
        // recheck it at the write; the ack waits for the confirmation.
        #expect(commands == [.applySessionUpsert(id: id, revision: 1, payload: "s1")])
        #expect(state.ackAge.isEmpty)
    }

    @Test("incoming revision ≤ stored routes to the drop path's store handshake", arguments: [
        (incoming: 1, stored: 1),
        (incoming: 1, stored: 2),
        (incoming: 5, stored: 9)
    ])
    func staleRevisionRoutesToConfirm(incoming: Int, stored: Int) {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: incoming, storedRevision: stored, payload: "ghost"),
            &state,
            now: t0
        )

        // No upsert — but no ack from the stale lookup either: the re-ack
        // the retrying watch is owed rides the atomic verification.
        #expect(commands == [.confirmSessionStored(id: id, revision: incoming)])
        #expect(state.ackAge.isEmpty)
    }

    @Test("incoming revision above stored wins the upsert route")
    func higherRevisionRoutesToUpsert() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: 3, storedRevision: 2, payload: "edited"),
            &state,
            now: t0
        )

        #expect(commands == [.applySessionUpsert(id: id, revision: 3, payload: "edited")])
    }

    @Test("only the store's confirmation earns the ack and publishes the digest")
    func confirmationEarnsAckAndPublishes() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        _ = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )

        let commands = machine.handle(.sessionStoreConfirmed(id: id), &state, now: t0)

        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
        #expect(state.ackAge == [id: 0])
    }

    @Test("a confirmation for an id the machine never routed is trusted — it is the runtime's store assertion")
    func unroutedConfirmationIsTrusted() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(.sessionStoreConfirmed(id: id), &state, now: t0)

        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
    }
}

@Suite("§5 phone machine — bounded ack retention (forward-only age)")
struct PhoneAckRetentionTests {
    let machine = TestPhoneMachine()
    let retention = TestPhoneMachine.Configuration().ackRetention

    /// Confirms `id` into `state` at `now` — the only way an ack is born.
    private func ack(_ id: UUID, _ state: inout TestPhoneMachine.State, at now: Date) {
        _ = machine.handle(.sessionStoreConfirmed(id: id), &state, now: now)
    }

    @Test("the default retention is 30 days")
    func defaultRetentionIsThirtyDays() {
        #expect(retention == 30 * 24 * 60 * 60)
    }

    @Test("an ack survives to just inside the bound and drops at it")
    func ackExpiresAtTheBound() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        ack(id, &state, at: t0)

        let inside = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(retention - 1))
        #expect(inside == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        let atBound = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(retention))
        #expect(atBound == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [])])
        #expect(state.ackAge.isEmpty)
    }

    @Test("a store-confirmed re-delivery resets the age")
    func confirmedRedeliveryResetsAge() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        ack(id, &state, at: t0)

        // A ghost re-delivery twenty days in, confirmed by the store,
        // restarts the clock…
        ack(id, &state, at: t0.addingTimeInterval(20 * 24 * 60 * 60))

        // …so at t0+35d (past the original bound, inside the reset one)
        // the ack is still published.
        let commands = machine.handle(
            .historyChanged,
            &state,
            now: t0.addingTimeInterval(35 * 24 * 60 * 60)
        )
        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
    }

    @Test("an oscillating clock cannot keep an ack alive — rollbacks add nothing, forward legs accumulate")
    func oscillatingClockCannotExtendRetention() {
        // m4-02 review 1, #2: under the stamp-based design, repeated
        // 29-days-forward/rollback cycles restarted the window forever.
        // Age accumulates only forward deltas, so two 29-day forward legs
        // total 58 days regardless of the rollbacks between them.
        var state = TestPhoneMachine.State()
        let id = UUID()
        let twentyNineDays: TimeInterval = 29 * 24 * 60 * 60
        ack(id, &state, at: t0)

        // Forward leg one: age 29 d — retained.
        let firstLeg = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(twentyNineDays))
        #expect(firstLeg == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        // Rollback to the origin: delta 0 — retained, window NOT restarted.
        let rollback = machine.handle(.historyChanged, &state, now: t0)
        #expect(rollback == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        // Forward leg two: 29 d more — accumulated 58 d ≥ 30 d, expired.
        let secondLeg = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(twentyNineDays))
        #expect(secondLeg == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [])])
        #expect(state.ackAge.isEmpty)
    }

    @Test("a rollback alone expires nothing; the correction after it ages acks early — the documented safe direction")
    func rollbackIsInertAndCorrectionAgesEarly() {
        // m4-02 review 1, #2's second trace. The rollback itself must be
        // inert (the stamp design could expire an ack instantly after
        // rollback + correction). The correction's forward jump *does*
        // count in full — it is indistinguishable from genuinely elapsed
        // time — so it can expire an ack early. Early is the safe
        // direction here, deliberately: an over-eager expiry just means
        // the watch retries and the redelivery re-earns the ack through
        // the store, while late expiry is unbounded state with no repair.
        var state = TestPhoneMachine.State()
        let id = UUID()
        let day100 = t0.addingTimeInterval(100 * 24 * 60 * 60)
        ack(id, &state, at: day100)

        // Clock rolls back 100 days: delta 0, ack untouched.
        let duringRollback = machine.handle(.historyChanged, &state, now: t0)
        #expect(duringRollback == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        // Correction back to day 100: +100 d of observed forward time —
        // expired (early relative to true elapsed time, by design).
        let afterCorrection = machine.handle(.historyChanged, &state, now: day100)
        #expect(afterCorrection == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [])])
    }

    @Test("a rehydrated over-age ack is swept even before the clock moves")
    func rehydratedOverAgeAckIsSwept() {
        var state = TestPhoneMachine.State(
            ackAge: [UUID(): retention + 1],
            lastObservedNow: t0
        )

        let commands = machine.handle(.historyChanged, &state, now: t0)

        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [])])
        #expect(state.ackAge.isEmpty)
    }
}

@Suite("§5 phone machine — digest regeneration triggers")
struct PhoneDigestTriggerTests {
    let machine = TestPhoneMachine()

    @Test("a history change republishes the digest with the current version and acks")
    func historyChangePublishes() {
        var state = TestPhoneMachine.State(
            ackAge: [UUID(): 0],
            lastObservedNow: t0,
            latestSnapshotVersion: 4
        )
        let acked = Set(state.ackAge.keys)

        let commands = machine.handle(.historyChanged, &state, now: t0)

        #expect(commands == [.publishDigest(snapshotVersion: 4, ackedSessionIDs: acked)])
    }
}

@Suite("§5 phone machine — snapshot version line and supersession")
struct PhoneSnapshotTests {
    let machine = TestPhoneMachine()

    @Test("a catalog change bumps the version once and transmits it")
    func catalogChangeBumpsAndTransmits() {
        var state = TestPhoneMachine.State()

        let commands = machine.handle(.catalogChanged, &state, now: t0)

        #expect(commands == [.transmitSnapshot(version: 1)])
        #expect(state.latestSnapshotVersion == 1)
        #expect(state.outstandingSnapshotVersion == 1)
    }

    @Test("a newer snapshot cancels the outstanding transfer before transmitting")
    func newerSnapshotSupersedes() {
        var state = TestPhoneMachine.State()
        _ = machine.handle(.catalogChanged, &state, now: t0)

        let commands = machine.handle(.catalogChanged, &state, now: t0.addingTimeInterval(5))

        #expect(commands == [
            .cancelSnapshotTransfer(version: 1),
            .transmitSnapshot(version: 2)
        ])
        #expect(state.outstandingSnapshotVersion == 2)
    }

    @Test("a push trigger re-sends the current version without bumping it")
    func pushTriggerResendsCurrentVersion() {
        var state = TestPhoneMachine.State(latestSnapshotVersion: 3)

        let commands = machine.handle(.snapshotPushTriggered, &state, now: t0)

        #expect(commands == [.transmitSnapshot(version: 3)])
        #expect(state.latestSnapshotVersion == 3)
        #expect(state.outstandingSnapshotVersion == 3)
    }

    @Test("a lost finished-callback cannot wedge push triggers — every push moment cancels and re-sends")
    func lostCallbackCannotWedgePushes() {
        // m4-02 review 1, #3: the skip-if-in-flight optimization returned
        // [] forever once the current version's finished callback was
        // lost — only a catalog edit could revive the pipeline. A push
        // moment now recovers unconditionally, and repeatably.
        var state = TestPhoneMachine.State()
        _ = machine.handle(.catalogChanged, &state, now: t0)
        // Version 1's transfer vanishes; its callback never arrives.

        let firstPush = machine.handle(.snapshotPushTriggered, &state, now: t0.addingTimeInterval(60))
        #expect(firstPush == [
            .cancelSnapshotTransfer(version: 1),
            .transmitSnapshot(version: 1)
        ])

        // And again on the next push moment — liveness does not depend on
        // any callback ever arriving.
        let secondPush = machine.handle(.snapshotPushTriggered, &state, now: t0.addingTimeInterval(120))
        #expect(secondPush == [
            .cancelSnapshotTransfer(version: 1),
            .transmitSnapshot(version: 1)
        ])
        #expect(state.outstandingSnapshotVersion == 1)
    }

    @Test("a push trigger over a stale outstanding transfer supersedes it like an edit would")
    func pushTriggerSupersedesStaleOutstanding() {
        // The stale transfer's finished callback was lost while the
        // catalog moved on: version 1 still occupies the slot at
        // catalog version 3.
        var state = TestPhoneMachine.State(
            latestSnapshotVersion: 3,
            outstandingSnapshotVersion: 1
        )

        let commands = machine.handle(.snapshotPushTriggered, &state, now: t0)

        #expect(commands == [
            .cancelSnapshotTransfer(version: 1),
            .transmitSnapshot(version: 3)
        ])
        #expect(state.outstandingSnapshotVersion == 3)
    }

    @Test("a finished transfer clears the outstanding slot; a late callback for a superseded one does not")
    func transferFinishedClearsOnlyMatchingVersion() {
        var state = TestPhoneMachine.State()
        _ = machine.handle(.catalogChanged, &state, now: t0)
        _ = machine.handle(.catalogChanged, &state, now: t0.addingTimeInterval(5))

        // The cancelled v1 transfer reports in late: v2 keeps the slot.
        _ = machine.handle(.snapshotTransferFinished(version: 1), &state, now: t0.addingTimeInterval(6))
        #expect(state.outstandingSnapshotVersion == 2)

        _ = machine.handle(.snapshotTransferFinished(version: 2), &state, now: t0.addingTimeInterval(7))
        #expect(state.outstandingSnapshotVersion == nil)
    }
}
