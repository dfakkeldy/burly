// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 acceptance #1: the state machines against a fake transport —
// dedupe on double delivery, out-of-order revisions,
// ack-then-ghost-redelivery, snapshot supersession, outbox retry-until-ack.
// Every scenario drives both machines through `SyncHarness`'s misbehaving
// channels; no WCSession, no store, no wall clock.
import Foundation
import Testing
import BurlySyncMachine

@Suite("§5 acceptance #1 — machines vs fake transport")
struct SyncConvergenceTests {
    @Test("outbox retry-until-ack: loss, a lying success callback, and retries — only the ack ends it")
    func outboxRetriesUntilAck() {
        var h = SyncHarness()
        let s = UUID()

        // Completion transmits immediately…
        h.watchCompletes(s)
        #expect(h.sessionChannel.count == 1)

        // …the transport loses it, and a success callback arrives anyway
        // (the attempt "finished" — the payload still never landed).
        h.loseQueuedSessions()
        h.watchReceivesTransferCallback(id: s, reportedSuccess: true)
        #expect(h.watchState.outbox.count == 1)

        // Every activation retries, however many it takes.
        h.watchActivates()
        h.loseQueuedSessions()
        h.watchActivates()
        #expect(h.sessionChannel.count == 1)

        // This attempt gets through; the phone acks; the digest lands.
        h.deliverNextSessionToPhone()
        #expect(h.latestDigest?.ackedSessionIDs == [s])
        h.deliverDigestToWatch()

        // Converged: outbox empty, working set pruned, retries over.
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.watchAwaitingAck.isEmpty)
        h.watchActivates()
        #expect(h.sessionChannel.isEmpty)
    }

    @Test("dedupe on double delivery: the same transfer landing twice upserts once")
    func doubleDeliveryUpsertsOnce() {
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)

        // The queued channel redelivers the identical entry twice (a retry
        // raced its own ack).
        let queued = h.sessionChannel[0]
        h.deliverSessionToPhone(queued)
        h.deliverSessionToPhone(queued)

        #expect(h.phoneUpsertCount == 1)
        #expect(h.phoneStoredRevisions[s] == 1)
        // Both deliveries re-published the ack — the second is exactly the
        // "watch never saw it" repair path.
        #expect(h.latestDigest?.ackedSessionIDs == [s])
    }

    @Test("out-of-order revisions: an older revision arriving late never overwrites a newer one")
    func outOfOrderRevisionsResolveByRule() {
        var h = SyncHarness()
        let s = UUID()

        // Revision 2 lands first (a re-send raced ahead), then revision 1
        // straggles in.
        h.deliverSessionToPhone(.init(id: s, revision: 2, payload: "rev2"))
        h.deliverSessionToPhone(.init(id: s, revision: 1, payload: "rev1"))
        #expect(h.phoneUpsertCount == 1)
        #expect(h.phoneStoredRevisions[s] == 2)

        // A genuinely newer revision still wins.
        h.deliverSessionToPhone(.init(id: s, revision: 3, payload: "rev3"))
        #expect(h.phoneUpsertCount == 2)
        #expect(h.phoneStoredRevisions[s] == 3)
    }

    @Test("a phone edit outranks the watch original forever after")
    func phoneEditOutranksRedelivery() {
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        let original = h.sessionChannel[0]
        h.deliverNextSessionToPhone()

        // §6 edit: applyPhoneEdit bumps the stored revision to 2.
        h.phoneEditsSession(s)

        // The watch original (revision 1) ghosts back — dropped silently.
        h.deliverSessionToPhone(original)
        #expect(h.phoneUpsertCount == 1)
        #expect(h.phoneStoredRevisions[s] == 2)
    }

    @Test("ack-then-ghost-redelivery: a ghost after the 30-day ack expiry is safe by upsert")
    func ghostAfterAckExpiryIsSafe() {
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        let ghost = h.sessionChannel[0]
        h.deliverNextSessionToPhone()
        h.deliverDigestToWatch()
        #expect(h.watchState.outbox.isEmpty)

        // 31 days later the ack has aged out of the digest.
        h.now.addTimeInterval(31 * 24 * 60 * 60)
        h.phoneHistoryChanges()
        #expect(h.latestDigest?.ackedSessionIDs == [])

        // Ghost, variant 1 — the session is still stored: dropped by the
        // revision rule, re-acked, nothing duplicated.
        h.deliverSessionToPhone(ghost)
        #expect(h.phoneUpsertCount == 1)
        #expect(h.latestDigest?.ackedSessionIDs == [s])

        // Ghost, variant 2 — the phone deleted it meanwhile: the upsert
        // recreates it whole. Deterministic, single row, re-acked — §5's
        // accepted trade for bounded ack state.
        h.now.addTimeInterval(31 * 24 * 60 * 60)
        h.phoneHistoryChanges()
        h.phoneDeletesSession(s)
        h.deliverSessionToPhone(ghost)
        #expect(h.phoneUpsertCount == 2)
        #expect(h.phoneStoredRevisions[s] == 1)
        #expect(h.latestDigest?.ackedSessionIDs == [s])

        // The watch, whose outbox emptied at the first ack, never moves
        // again through any of it.
        h.deliverDigestToWatch()
        h.watchActivates()
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.sessionChannel.count(where: { $0.id == s }) == 0)
    }

    @Test("snapshot supersession: the newer snapshot cancels the outstanding one, and the stale file is dropped on arrival")
    func snapshotSupersessionEndToEnd() {
        var h = SyncHarness()

        h.phoneCatalogChanges()
        h.phoneCatalogChanges()

        // v1's transfer was cancelled; v2's is live.
        #expect(h.snapshotChannel == [
            .init(version: 1, cancelled: true),
            .init(version: 2, cancelled: false)
        ])

        // v2 lands first; the cancelled v1 straggles in anyway (a transfer
        // the transport had already completed when the cancel arrived).
        h.deliverSnapshotToWatch(h.snapshotChannel[1])
        h.deliverSnapshotToWatch(h.snapshotChannel[0])

        // Exactly one whole-replace, at the newer version.
        #expect(h.watchAppliedSnapshotVersions == [2])
        #expect(h.watchState.lastAppliedSnapshotVersion == 2)

        // The late finished-callback for cancelled v1 does not clear v2's
        // outstanding slot; v2's own does.
        h.phoneSnapshotTransferFinishes(version: 1)
        #expect(h.phoneState.outstandingSnapshotVersion == 2)
        h.phoneSnapshotTransferFinishes(version: 2)
        #expect(h.phoneState.outstandingSnapshotVersion == nil)
    }

    @Test("phone-deleted history: an entry-less digest still converges the watch working set to zero and strands nothing")
    func entrylessDigestConvergesWorkingSet() {
        // Carried from m1-06 review round 4. The watch finishes the only
        // session ever; the phone receives and acks it; the user deletes it
        // on the phone. The next digest honestly carries no last-performance
        // entries and still carries the ack — and it must act, because the
        // acks age out and no later digest will ever name the session again.
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        h.deliverNextSessionToPhone()
        h.phoneDeletesSession(s)
        h.phoneHistoryChanges() // digest now derived from empty history

        #expect(h.latestDigest?.ackedSessionIDs == [s])
        h.deliverDigestToWatch()

        // Converged: zero delivered-and-acked sessions anywhere on the
        // watch, and the digest was applied, not refused.
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.watchAwaitingAck.isEmpty)
        #expect(h.watchAppliedDigestCount == 1)

        // Past ack expiry nothing re-strands: later digests without the id
        // apply cleanly and no activation ever retransmits it.
        h.now.addTimeInterval(31 * 24 * 60 * 60)
        h.phoneHistoryChanges()
        #expect(h.latestDigest?.ackedSessionIDs == [])
        h.deliverDigestToWatch()
        h.watchActivates()
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.watchAwaitingAck.isEmpty)
        #expect(h.sessionChannel.isEmpty)
        #expect(h.watchAppliedDigestCount == 2)
    }

    @Test("a two-session backlog drains in order and partial acks keep the rest retrying")
    func partialAcksKeepRemainderRetrying() {
        var h = SyncHarness()
        let first = UUID()
        let second = UUID()
        h.watchCompletes(first)
        h.watchCompletes(second)

        // Only the first delivery makes it before the phone goes quiet.
        h.deliverNextSessionToPhone()
        h.deliverDigestToWatch()
        #expect(h.watchState.outbox.map(\.id) == [second])
        #expect(h.watchAwaitingAck == [second])

        // The next activation retries exactly the unacked one.
        h.loseQueuedSessions()
        h.watchActivates()
        #expect(h.sessionChannel.map(\.id) == [second])

        h.deliverNextSessionToPhone()
        h.deliverDigestToWatch()
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.watchAwaitingAck.isEmpty)
        #expect(h.latestDigest?.ackedSessionIDs == [first, second])
    }
}
