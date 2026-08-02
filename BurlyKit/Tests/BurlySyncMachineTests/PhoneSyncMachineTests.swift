// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 phone-side rules, each pinned directly against the machine:
// the idempotent upsert rule (incoming revision ≤ stored → drop silently),
// unconditional re-acking, the 30-day bounded ack retention under an
// injected `now`, digest regeneration triggers, and the snapshot version
// line with supersession.
import Foundation
import Testing
import BurlySyncMachine

typealias TestPhoneMachine = PhoneSyncMachine<String>

/// A fixed origin so every test advances time explicitly — there is no
/// `Date()` anywhere in these tests or in the machine they drive.
private let t0 = Date(timeIntervalSinceReferenceDate: 0)

@Suite("§5 phone machine — session ingest")
struct PhoneIngestTests {
    let machine = TestPhoneMachine()

    @Test("an unstored session applies, is acked, and refreshes the digest — in that order")
    func newSessionAppliesAcksAndPublishes() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )

        // Upsert strictly before publish: the digest must be derived from
        // history that already contains the session it acks.
        #expect(commands == [
            .applySessionUpsert(id: id, payload: "s1"),
            .publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])
        ])
        #expect(state.ackedAt == [id: t0])
    }

    @Test("incoming revision ≤ stored drops silently but still re-acks", arguments: [
        (incoming: 1, stored: 1),
        (incoming: 1, stored: 2),
        (incoming: 5, stored: 9)
    ])
    func staleRevisionDropsButReAcks(incoming: Int, stored: Int) {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: incoming, storedRevision: stored, payload: "ghost"),
            &state,
            now: t0
        )

        // No upsert — but the watch retried because it lacks the ack, so
        // the ack is (re)published all the same.
        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
        #expect(state.ackedAt == [id: t0])
    }

    @Test("incoming revision above stored wins the upsert")
    func higherRevisionApplies() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let commands = machine.handle(
            .sessionReceived(id: id, revision: 3, storedRevision: 2, payload: "edited"),
            &state,
            now: t0
        )

        #expect(commands == [
            .applySessionUpsert(id: id, payload: "edited"),
            .publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])
        ])
    }

    @Test("double delivery upserts exactly once")
    func doubleDeliveryDedupes() {
        var state = TestPhoneMachine.State()
        let id = UUID()

        let first = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )
        // The runtime stored it, so the second delivery sees revision 1.
        let second = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: 1, payload: "s1"),
            &state,
            now: t0.addingTimeInterval(60)
        )

        #expect(first.contains(.applySessionUpsert(id: id, payload: "s1")))
        #expect(second == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
    }
}

@Suite("§5 phone machine — bounded ack retention")
struct PhoneAckRetentionTests {
    let machine = TestPhoneMachine()
    let retention = TestPhoneMachine.Configuration().ackRetention

    @Test("the default retention is 30 days")
    func defaultRetentionIsThirtyDays() {
        #expect(retention == 30 * 24 * 60 * 60)
    }

    @Test("an ack survives to just inside the bound and drops at it")
    func ackExpiresAtTheBound() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        _ = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )

        let inside = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(retention - 1))
        #expect(inside == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        let atBound = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(retention))
        #expect(atBound == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [])])
        #expect(state.ackedAt.isEmpty)
    }

    @Test("a re-delivery restamps the retention window")
    func redeliveryRestampsRetention() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        _ = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )

        // A ghost re-delivery twenty days in restarts the clock…
        let twentyDays = t0.addingTimeInterval(20 * 24 * 60 * 60)
        _ = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: 1, payload: "s1"),
            &state,
            now: twentyDays
        )

        // …so at t0+35d (past the original bound, inside the restamped
        // one) the ack is still published.
        let thirtyFiveDays = t0.addingTimeInterval(35 * 24 * 60 * 60)
        let commands = machine.handle(.historyChanged, &state, now: thirtyFiveDays)
        #expect(commands == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])
    }

    @Test("a ghost after ack expiry is safe by the upsert rule, stored or not")
    func ghostAfterExpiryIsSafe() {
        var state = TestPhoneMachine.State()
        let id = UUID()
        _ = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &state,
            now: t0
        )
        let afterExpiry = t0.addingTimeInterval(retention + 1)

        // Still stored: the revision rule drops it, the ack returns.
        let stillStored = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: 1, payload: "s1"),
            &state,
            now: afterExpiry
        )
        #expect(stillStored == [.publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])])

        // Deleted meanwhile (§1 deleteSession): the upsert recreates it
        // whole — one deterministic command, no duplicate, no error path.
        // §5's accepted trade for keeping ack state bounded.
        var deletedState = TestPhoneMachine.State()
        let deleted = machine.handle(
            .sessionReceived(id: id, revision: 1, storedRevision: nil, payload: "s1"),
            &deletedState,
            now: afterExpiry
        )
        #expect(deleted == [
            .applySessionUpsert(id: id, payload: "s1"),
            .publishDigest(snapshotVersion: 0, ackedSessionIDs: [id])
        ])
    }

    @Test("an ack stamped in the future re-anchors to now instead of outliving the bound")
    func futureStampedAckReAnchors() {
        // The wall clock can run backwards (NTP, manual date change). An
        // ack stamped "later than now" must not ride the original stamp to
        // an effectively longer retention — it restarts from the moment
        // the machine noticed, exactly like the weight-edit idle anchor.
        var state = TestPhoneMachine.State(ackedAt: [UUID(): t0.addingTimeInterval(10_000)])
        let machine = TestPhoneMachine()

        _ = machine.handle(.historyChanged, &state, now: t0)
        #expect(state.ackedAt.values.allSatisfy { $0 == t0 })

        // Re-anchored at t0, it expires one full retention later — not
        // 10 000 s after that.
        _ = machine.handle(.historyChanged, &state, now: t0.addingTimeInterval(retention))
        #expect(state.ackedAt.isEmpty)
    }
}

@Suite("§5 phone machine — digest regeneration triggers")
struct PhoneDigestTriggerTests {
    let machine = TestPhoneMachine()

    @Test("a history change republishes the digest with the current version and acks")
    func historyChangePublishes() {
        var state = TestPhoneMachine.State(
            ackedAt: [UUID(): t0],
            latestSnapshotVersion: 4
        )
        let acked = Set(state.ackedAt.keys)

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

    @Test("a push trigger while the current version is already in flight does nothing")
    func pushTriggerSkipsWhileCurrentInFlight() {
        var state = TestPhoneMachine.State()
        _ = machine.handle(.catalogChanged, &state, now: t0)

        let commands = machine.handle(.snapshotPushTriggered, &state, now: t0.addingTimeInterval(1))

        #expect(commands.isEmpty)
        #expect(state.outstandingSnapshotVersion == 1)
    }

    @Test("a push trigger over a stale outstanding transfer supersedes it like an edit would")
    func pushTriggerSupersedesStaleOutstanding() {
        // Reachable when the stale transfer's finished callback was lost
        // (e.g. a relaunch): version 1 still occupies the slot while the
        // catalog is already at 3.
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
