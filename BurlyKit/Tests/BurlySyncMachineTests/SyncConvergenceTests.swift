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
            .init(version: 1, generation: 1, cancelled: true),
            .init(version: 2, generation: 2, cancelled: false)
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
        h.phoneSnapshotTransferFinishes(version: 1, generation: 1)
        #expect(h.phoneState.outstandingSnapshot == .init(version: 2, generation: 2))
        h.phoneSnapshotTransferFinishes(version: 2, generation: 2)
        #expect(h.phoneState.outstandingSnapshot == nil)
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

    @Test("conflicting same-id completions converge on the pinned payload in every delivery order")
    func sameIDCompletionsConvergeRegardlessOfOrder() {
        // m4-02 review 1, #1: with payload replacement, delivering A first
        // stored A forever and delivering B first stored B — the transport
        // picked the winner. Pinning means only one serialization ever
        // reaches the wire, so both orders converge on it.
        let s = UUID()

        for reversed in [false, true] {
            var h = SyncHarness()
            h.watchCompletes(s, payload: "payload-A")
            h.watchCompletes(s, payload: "payload-B") // replay with different bytes
            #expect(h.sessionChannel.map(\.payload) == ["payload-A", "payload-A"])

            let deliveries = reversed ? [1, 0] : [0, 1]
            for index in deliveries {
                h.deliverSessionToPhone(h.sessionChannel[index])
            }

            #expect(h.phoneStoredPayloads[s] == "payload-A")
            #expect(h.phoneUpsertCount == 1)
            #expect(h.latestDigest?.ackedSessionIDs == [s])
        }
    }

    @Test("a resurrection after ack-and-prune never transmits, and stale queued copies converge identically in both orders")
    func resurrectionAfterAckPruneCannotReopenPayloadRace() {
        // m4-02 review 2, #1's full trace. Round 1's pin lived in the
        // outbox entry, so the ack that pruned the entry also removed the
        // pin: a later same-id completion re-entered the outbox and
        // transport order decided the recreated payload again. Now the
        // remembered acked set refuses the resurrection outright, so the
        // only bytes ever on the wire are the original pinned A copies —
        // and every delivery order of those converges on A.
        let s = UUID()

        for reversed in [false, true] {
            var h = SyncHarness()
            h.watchCompletes(s, payload: "payload-A")
            h.watchActivates() // a stale retry copy queues: channel [A, A]
            #expect(h.sessionChannel.map(\.payload) == ["payload-A", "payload-A"])

            // First copy delivers; the ack lands; the pin is pruned.
            h.deliverSessionToPhone(h.sessionChannel[0])
            h.deliverDigestToWatch()
            #expect(h.watchState.outbox.isEmpty)

            // Upstream bug: the same id "completes" again with different
            // bytes. Refused — reported, nothing queued, nothing new on
            // the wire.
            h.watchCompletes(s, payload: "payload-B")
            #expect(h.watchStaleCompletionReports == [s])
            #expect(h.watchState.outbox.isEmpty)
            #expect(h.sessionChannel.map(\.payload) == ["payload-A", "payload-A"])

            // The phone deletes the session; the stale queued A copies
            // then land against an absent row, in either order.
            h.phoneDeletesSession(s)
            let deliveries = reversed ? [1, 0] : [0, 1]
            for index in deliveries {
                h.deliverSessionToPhone(h.sessionChannel[index])
            }

            // Both orders recreate the same payload: A, exactly once.
            #expect(h.phoneStoredPayloads[s] == "payload-A")
            #expect(h.phoneStoredRevisions[s] == 1)

            // And the working set converges: the re-ack prunes the
            // resurrected store row on the next digest delivery.
            h.deliverDigestToWatch()
            #expect(h.watchAwaitingAck.isEmpty)
            #expect(h.watchState.outbox.isEmpty)
        }
    }

    @Test("uncorrelated confirmations are inert end-to-end: duplicates, crash-era replays, and never-routed ids")
    func uncorrelatedConfirmationsAreInert() {
        // m4-02 review 2, #3's fault injections against the full harness.
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        h.deliverNextSessionToPhone()
        #expect(h.phoneState.ackAge[s] == 0)
        let digestAfterRealConfirmation = h.latestDigest

        // Duplicate confirmation: no ack reset, no new publication.
        // (`oneDay` typed explicitly — `#expect` evaluates a bare
        // integer-literal product as Int and its Optional<Double>-vs-Int
        // comparison is false even for equal values.)
        let oneDay: TimeInterval = 24 * 60 * 60
        h.now.addTimeInterval(oneDay)
        h.injectStoreConfirmation(s)
        #expect(h.phoneState.ackAge[s] == oneDay)
        #expect(h.latestDigest == digestAfterRealConfirmation)

        // Never-routed id: nothing appears anywhere.
        let ghost = UUID()
        h.injectStoreConfirmation(ghost)
        #expect(h.phoneState.ackAge[ghost] == nil)
        #expect(h.latestDigest == digestAfterRealConfirmation)

        // Crash-and-rehydrate from the persisted state (ack present,
        // pending slot long consumed), then a transport-level replay of
        // the old confirmation: still inert.
        let persisted = h.phoneState
        h.rehydratePhone(from: persisted)
        h.injectStoreConfirmation(s)
        #expect(h.phoneState.ackAge[s] == oneDay)
        #expect(h.latestDigest == digestAfterRealConfirmation)
    }

    @Test("a stale drop decision racing a delete cannot ack an unstored session — the verify re-drives instead")
    func staleDropRaceCannotLeakAck() {
        // m4-02 review 1, #4's data-loss trace, verbatim: the runtime
        // read storedRevision 1, a concurrent phone delete removed the
        // row, and the machine's arrival-time ack then let the watch
        // prune its only durable copy. Now the drop path's ack rides an
        // atomic store verification; when the row is gone, the payload
        // re-drives as a fresh arrival and the ack is only earned once
        // the store durably holds the session again.
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        let queued = h.sessionChannel[0]
        h.deliverNextSessionToPhone()
        #expect(h.phoneStoredRevisions[s] == 1)

        // The race: a redelivery is processed against a lookup that said
        // "stored at revision 1" — but the row was deleted in between.
        h.phoneDeletesSession(s)
        h.deliverSessionToPhone(queued, staleStoredRevision: .some(1))

        // No ack without a stored row: the re-drive recreated the session,
        // and only then did the digest name it. The invariant the old
        // behavior violated: an acked id is a stored id.
        #expect(h.phoneStoredRevisions[s] == 1)
        #expect(h.phoneStoredPayloads[s] == queued.payload)
        #expect(h.latestDigest?.ackedSessionIDs == [s])
        for acked in h.latestDigest?.ackedSessionIDs ?? [] {
            #expect(h.phoneStoredRevisions[acked] != nil)
        }
    }

    @Test("a stale-low lookup racing a phone edit cannot overwrite the newer row — the write rechecks")
    func staleLowRaceCannotOverwriteNewerRow() {
        // The inverse race from review #4: the lookup said revision 1, a
        // §6 edit raised the store to 3 before the machine decided, and
        // the resulting upsert command would have clobbered the edit. The
        // binding contract's conditional write drops it at the store and
        // still confirms (an equal/newer row exists), so the watch gets
        // its ack without the edit being lost.
        var h = SyncHarness()
        let s = UUID()
        h.watchCompletes(s)
        h.deliverNextSessionToPhone()
        let editedPayloadBefore = h.phoneStoredPayloads[s]
        h.phoneEditsSession(s) // stored revision 2
        h.phoneEditsSession(s) // stored revision 3

        // A revision-2 ghost decided against a stale "stored revision 1".
        h.deliverSessionToPhone(
            .init(id: s, revision: 2, payload: "stale-overwrite"),
            staleStoredRevision: .some(1)
        )

        #expect(h.phoneStoredRevisions[s] == 3)
        #expect(h.phoneStoredPayloads[s] == editedPayloadBefore)
        #expect(h.latestDigest?.ackedSessionIDs == [s])
    }

    @Test("a failed upsert commit confirms nothing — no ack escapes, and the retry completes the exchange")
    func failedCommitLeaksNoAck() {
        // Binding contract item 3 (review #4's durability edge): the old
        // machine mutated its ack state before the upsert command was
        // known to have committed, so a failed transaction could still
        // publish an ack for data the phone never stored.
        var h = SyncHarness()
        let s = UUID()
        h.failNextUpsertCommit = true
        h.watchCompletes(s)
        h.deliverNextSessionToPhone()

        // Nothing stored, nothing acked, nothing published.
        #expect(h.phoneStoredRevisions[s] == nil)
        #expect(h.phoneState.ackAge.isEmpty)
        #expect(h.latestDigest == nil)
        #expect(h.watchState.outbox.count == 1)

        // The watch's normal retry re-drives the whole exchange to
        // convergence.
        h.watchActivates()
        h.deliverNextSessionToPhone()
        h.deliverDigestToWatch()
        #expect(h.phoneStoredRevisions[s] == 1)
        #expect(h.latestDigest?.ackedSessionIDs == [s])
        #expect(h.watchState.outbox.isEmpty)
        #expect(h.watchAwaitingAck.isEmpty)
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
