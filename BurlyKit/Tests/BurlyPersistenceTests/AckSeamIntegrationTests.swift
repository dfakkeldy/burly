// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #6 — the pruning gate.
//
// "after a simulated ack, the delivered session is absent from the watch
//  container (BurlySync + BurlyPersistence integration test)."
//
// This is the one test in the task that has to cross both modules: it
// drives the ack through BurlySync's `SessionDigestReceipt` /
// `SessionDigestApplying` seam, not through `pruneDeliveredSessions`
// directly (that's WatchWorkingSetTests' job), and it does so disk-backed
// with a cold reopen — the same rationale CascadeTests uses: a prune that
// merely orphaned rows in the live context could still look clean without a
// fresh container over the same file.
//
// The seam carries the whole §5 `digest` now, not just the ids (m1-06
// review round D), so these tests hand it both halves — that is the shape
// M4's courier will produce, and the shape that cannot commit a prune
// without the entries it arrived with.

import Foundation
import SwiftData
import Testing
import BurlyCore
import BurlySync
@testable import BurlyPersistence

@Suite("§1 #6 — ack seam prunes delivered sessions from the watch container")
struct AckSeamIntegrationTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    @Test("acked .logged sessions are absent after a cold reopen; the .active session, exercises, routines, and last-performance digests survive untouched")
    func ackedSessionsArePrunedAcrossColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])

        let emptyLoggedOne = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let loggedOneSet = SetRecordData(
            order: 0, weight: Weight(kg: 80), reps: 5, completedAt: Fixture.epoch
        )
        let loggedOneSetID = loggedOneSet.id
        let loggedOne = emptyLoggedOne.addingSet(
            loggedOneSet, toItem: try #require(emptyLoggedOne.items.first?.id)
        )
        let loggedTwo = Fixture.session(
            from: routine, startedAt: Fixture.epoch.addingTimeInterval(3_600)
        )
        var active = Fixture.activeSession(
            from: routine, startedAt: Fixture.epoch.addingTimeInterval(7_200)
        )
        let activeItemID = try #require(active.items.first?.id)

        // The digest half of the payload the seam carries. `loggedOne` lifted
        // bench, so a digest acking it *must* carry a bench entry (m1-06
        // review round E) — the phone derives latest-per-exercise from full
        // history, so a payload that admits to having this session and
        // claims to know nothing about its exercises is a contradiction the
        // store refuses. The stale bench entry seeded below is what the
        // arriving one overwrites, latest-wins, in the same save as the
        // prune.
        let staleBenchDigest = ExerciseLastPerformanceData(
            exerciseID: bench.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: 80), reps: 5)]
        )
        let arrivingBenchDigest = ExerciseLastPerformanceData(
            exerciseID: bench.id,
            performedAt: Fixture.epoch.addingTimeInterval(7_200),
            sets: [SetSnapshot(weight: Weight(kg: 85), reps: 3)]
        )
        let arrivingRowDigest = ExerciseLastPerformanceData(
            exerciseID: row.id,
            performedAt: Fixture.epoch.addingTimeInterval(3_600),
            sets: [SetSnapshot(weight: Weight(kg: 70), reps: 10)]
        )

        // ---- write the working set, apply the digest, let the writer go out of scope ----
        do {
            // Fixed store clock so the "routines are untouched by the
            // prune" assertion below can compare whole `RoutineData`
            // values: `createRoutine` stamps a store-owned `updatedAt`
            // (m1-06 review, m2).
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: TestClock())
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)
            try store.createSession(loggedOne)
            try store.createSession(loggedTwo)
            try store.upsertLastPerformance(staleBenchDigest)

            try SessionMutator.logSet(
                itemID: activeItemID,
                weight: Weight(kg: 60),
                reps: 8,
                in: &active,
                clock: TestClock(Fixture.epoch)
            )
            try store.saveActiveSession(active)

            #expect(try store.loggedSessionsAwaitingAck().count == 2)

            // Drive the whole digest through the BurlySync seam, not the
            // store API directly — this is the integration point the gate
            // names. `active.id` rides along in the receipt too, proving
            // the .active refusal holds even when a transport
            // (incorrectly) includes it.
            let sync: SessionDigestApplying = store
            try sync.apply(
                SessionDigestReceipt(
                    lastPerformance: [arrivingBenchDigest, arrivingRowDigest],
                    ackedSessionIDs: [loggedOne.id, loggedTwo.id, active.id]
                )
            )
        }

        // ---- cold open: a brand-new container over the same file ----
        let container = try BurlyContainer.make(.watch, at: .file(url))
        let reopened = SwiftDataStore(container: container)

        // The delivered sessions are gone — by id fetch, not just count.
        #expect(try reopened.session(id: loggedOne.id) == nil)
        #expect(try reopened.session(id: loggedTwo.id) == nil)
        #expect(try reopened.loggedSessionsAwaitingAck().isEmpty)
        #expect(try rowCount(Session.self, in: container) == 1)

        // Cascaded children are genuinely gone, not orphaned.
        let context = ModelContext(container)
        let setDescriptor = FetchDescriptor<SetRecord>(
            predicate: #Predicate { $0.id == loggedOneSetID }
        )
        #expect(try context.fetch(setDescriptor).isEmpty)

        // The .active session survived, refused despite being acked, with
        // its own item and set intact.
        let survivor = try #require(try reopened.session(id: active.id))
        #expect(survivor.state == .active)
        // One item per routine exercise (bench, row) — only the one we
        // logged a set on should carry it.
        #expect(survivor.items.count == 2)
        let loggedItem = try #require(survivor.items.first { $0.id == activeItemID })
        #expect(loggedItem.sets.count == 1)
        #expect(loggedItem.sets.first?.weightKg == 60)

        // Exercises and routines are untouched by the prune.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try reopened.exercise(id: bench.id) == bench)
        #expect(try reopened.exercise(id: row.id) == row)
        #expect(try rowCount(Routine.self, in: container) == 1)
        #expect(try reopened.routine(id: routine.id) == routine)

        // The bench ghost row is the replacement for the history this ack
        // just deleted, and it is the *arriving* value, not the stale one it
        // overwrote — the point of applying both halves in one save.
        let benchDigest = try #require(try reopened.lastPerformance(exerciseID: bench.id))
        #expect(benchDigest == arrivingBenchDigest)
        #expect(benchDigest != staleBenchDigest)

        // Both halves of the receipt landed in the same transaction: the
        // entry that arrived with the ack is durable across the cold reopen
        // alongside the prune it travelled with. A seam that could only
        // carry ids would have committed the prune with nothing here.
        #expect(try reopened.lastPerformance(exerciseID: row.id) == arrivingRowDigest)
        #expect(try rowCount(ExerciseLastPerformance.self, in: container) == 2)
    }

    // MARK: - Replay, duplicate, and ordering idempotency (m1-03 review)
    //
    // The gate above gets one disk-backed pass through the seam. These are
    // unit-level, in-memory pins for replay semantics that review found
    // "correct by inspection" against `pruneDeliveredSessions(ackedIDs:)`
    // (fetch-by-id + `.logged` check per id, `continue` past a miss, one
    // `save()` at the end) but not yet pinned by a test: a courier that
    // retries, coalesces, or reorders an ack must not be able to regress
    // this without a red test.

    @Test("applying the exact same SessionDigestReceipt twice is a no-op the second time: no throw, no additional deletions, store state identical")
    func replayingTheSameReceiptIsANoOp() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        // A session with a set in it, and a receipt carrying the matching
        // entry — the shape a real §5 push has (m1-06 review round E). The
        // earlier version of this test acked a set-less session with an
        // empty entry list, which passes but quietly documents the wrong
        // default; replay semantics are worth pinning against a payload a
        // courier would actually send.
        let emptyLogged = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let logged = emptyLogged.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 140), reps: 3, completedAt: Fixture.epoch),
            toItem: try #require(emptyLogged.items.first?.id)
        )
        // `survivor` is `.active` — a control that would catch a replay
        // that (incorrectly) re-walks and disturbs unrelated rows.
        let survivor = Fixture.activeSession(
            from: routine, startedAt: Fixture.epoch.addingTimeInterval(60)
        )
        try store.createSession(logged)
        try store.saveActiveSession(survivor)

        let sync: SessionDigestApplying = store
        let receipt = SessionDigestReceipt(
            lastPerformance: [
                ExerciseLastPerformanceData(
                    exerciseID: squat.id,
                    performedAt: Fixture.epoch,
                    sets: [SetSnapshot(weight: Weight(kg: 140), reps: 3)]
                )
            ],
            ackedSessionIDs: [logged.id]
        )

        try sync.apply(receipt)
        #expect(try store.session(id: logged.id) == nil)
        let survivorAfterFirstApply = try #require(try store.session(id: survivor.id))
        let digestAfterFirstApply = try #require(try store.lastPerformance(exerciseID: squat.id))
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)

        // Replay the identical receipt value. Must not throw — a session
        // already pruned reads as an "unknown id" to the second pass, and
        // that is the documented non-error case, not a failure. Note the
        // second pass now demands nothing of the entries either: the
        // coverage check is scoped to what the prune destroys, and this
        // time it destroys nothing.
        try sync.apply(receipt)
        #expect(try store.session(id: logged.id) == nil)
        let survivorAfterSecondApply = try #require(try store.session(id: survivor.id))
        #expect(survivorAfterSecondApply == survivorAfterFirstApply)
        #expect(try store.lastPerformance(exerciseID: squat.id) == digestAfterFirstApply)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
    }

    @Test("a receipt naming the same id more than once prunes it exactly once, without throwing, and leaves other logged sessions untouched")
    func duplicateIDsWithinOneReceiptPruneOnce() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let target = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let other = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try store.createSession(target)
        try store.createSession(other)

        let sync: SessionDigestApplying = store
        // The duplicate entries name a session that, after the first
        // deletion, no longer exists — the second and third occurrences
        // must fall through the same "unknown id" `continue` as a genuine
        // miss, not throw or double-delete.
        try sync.apply(
            SessionDigestReceipt(
                lastPerformance: [],
                ackedSessionIDs: [target.id, target.id, target.id]
            )
        )

        #expect(try store.session(id: target.id) == nil)
        #expect(try store.session(id: other.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [other.id])
    }

    @Test("an unknown id ordered before valid ids does not halt processing; the valid .logged sessions after it are still pruned")
    func unknownIDBeforeValidIDsDoesNotHaltProcessing() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let first = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let second = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try store.createSession(first)
        try store.createSession(second)

        let sync: SessionDigestApplying = store
        try sync.apply(
            SessionDigestReceipt(
                lastPerformance: [],
                ackedSessionIDs: [UUID(), first.id, second.id]
            )
        )

        #expect(try store.session(id: first.id) == nil)
        #expect(try store.session(id: second.id) == nil)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
    }

    @Test("the same acked ids, applied in different orders across two stores, converge on identical end state")
    func sameIDsInDifferentOrdersConvergeOnIdenticalState() throws {
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        // Shared ids, not merely structurally-equal fixtures — the point
        // is that the *same* acked ids converge regardless of the order a
        // transport happens to list them in.
        let idA = UUID()
        let idB = UUID()
        let survivorID = UUID()

        // Both acked sessions carry sets, so the receipt below has to carry
        // the squat entry (m1-06 review round E) — same reasoning as the
        // replay test: order-independence is worth pinning against the
        // payload shape a courier actually sends, not against an empty one.
        let squatDigest = ExerciseLastPerformanceData(
            exerciseID: squat.id,
            performedAt: Fixture.epoch.addingTimeInterval(60),
            sets: [SetSnapshot(weight: Weight(kg: 145), reps: 3)]
        )

        func seededStore() throws -> SwiftDataStore {
            let store = try makeStore(.watch)
            try store.createExercise(squat)
            try store.createRoutine(routine)
            let emptyA = Fixture.session(id: idA, from: routine, startedAt: Fixture.epoch)
            let a = emptyA.addingSet(
                SetRecordData(order: 0, weight: Weight(kg: 140), reps: 3, completedAt: Fixture.epoch),
                toItem: try #require(emptyA.items.first?.id)
            )
            let emptyB = Fixture.session(id: idB, from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
            let b = emptyB.addingSet(
                SetRecordData(order: 0, weight: Weight(kg: 145), reps: 3, completedAt: Fixture.epoch),
                toItem: try #require(emptyB.items.first?.id)
            )
            try store.createSession(a)
            try store.createSession(b)
            // `survivor` is `.active`, so it goes in through the one path
            // that can create one. Its id is fixed; its item ids are not
            // (see the comment on the comparison below).
            let survivor = Fixture.activeSession(
                id: survivorID, from: routine, startedAt: Fixture.epoch.addingTimeInterval(120)
            )
            try store.saveActiveSession(survivor)
            return store
        }

        let storeOne = try seededStore()
        let storeTwo = try seededStore()
        let syncOne: SessionDigestApplying = storeOne
        let syncTwo: SessionDigestApplying = storeTwo

        try syncOne.apply(
            SessionDigestReceipt(lastPerformance: [squatDigest], ackedSessionIDs: [idA, idB])
        )
        try syncTwo.apply(
            SessionDigestReceipt(lastPerformance: [squatDigest], ackedSessionIDs: [idB, idA])
        )

        #expect(try storeOne.session(id: idA) == nil)
        #expect(try storeOne.session(id: idB) == nil)
        #expect(try storeTwo.session(id: idA) == nil)
        #expect(try storeTwo.session(id: idB) == nil)
        #expect(try storeOne.loggedSessionsAwaitingAck().isEmpty)
        #expect(try storeTwo.loggedSessionsAwaitingAck().isEmpty)
        // The replacement ghost row converged too, not just the prune.
        #expect(try storeOne.lastPerformance(exerciseID: squat.id) == squatDigest)
        #expect(try storeTwo.lastPerformance(exerciseID: squat.id) == squatDigest)

        // Compare the fields the ack seam can actually influence, not
        // `SessionItemData.id` — `Fixture.session` mints a fresh random id
        // per item on every call (see `SessionItemData.init`), so the two
        // independently-seeded survivors never share item ids even though
        // pruning left both of them byte-for-byte untouched. Full
        // `SessionData` equality would fail on that irrelevant noise.
        let survivorOne = try #require(try storeOne.session(id: survivorID))
        let survivorTwo = try #require(try storeTwo.session(id: survivorID))
        #expect(survivorOne.id == survivorTwo.id)
        #expect(survivorOne.state == .active)
        #expect(survivorOne.state == survivorTwo.state)
        #expect(survivorOne.routineID == survivorTwo.routineID)
        #expect(survivorOne.startedAt == survivorTwo.startedAt)
        #expect(survivorOne.revision == survivorTwo.revision)
        #expect(survivorOne.items.map(\.exerciseID) == survivorTwo.items.map(\.exerciseID))
        #expect(survivorOne.items.map(\.order) == survivorTwo.items.map(\.order))
        #expect(survivorOne.items.map(\.sets) == survivorTwo.items.map(\.sets))
    }
}
