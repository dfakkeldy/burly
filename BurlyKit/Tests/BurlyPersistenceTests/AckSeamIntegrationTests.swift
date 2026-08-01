// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #6 — the pruning gate.
//
// "after a simulated ack, the delivered session is absent from the watch
//  container (BurlySync + BurlyPersistence integration test)."
//
// This is the one test in the task that has to cross both modules: it
// drives the ack through BurlySync's `SessionAckReceipt` /
// `SessionAckApplying` seam, not through `pruneDeliveredSessions` directly
// (that's WatchWorkingSetTests' job), and it does so disk-backed with a
// cold reopen — the same rationale CascadeTests uses: a prune that merely
// orphaned rows in the live context could still look clean without a
// fresh container over the same file.

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

        var loggedOne = Fixture.session(from: routine, startedAt: Fixture.epoch)
        loggedOne.state = .logged
        var loggedTwo = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(3_600))
        loggedTwo.state = .logged
        let active = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(7_200))
        // defaults to .active

        let digest = ExerciseLastPerformanceData(
            exerciseID: bench.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: 80), reps: 5)]
        )

        var loggedOneSetID: UUID = UUID()
        var activeItemID: UUID = UUID()

        // ---- write the working set, apply the ack, let the writer go out of scope ----
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)
            try store.createSession(loggedOne)
            try store.createSession(loggedTwo)
            try store.createSession(active)
            try store.upsertLastPerformance(digest)

            let firstItemID = try #require(loggedOne.items.first?.id)
            let loggedOneSet = SetRecordData(
                order: 0, weight: Weight(kg: 80), reps: 5, completedAt: Fixture.epoch
            )
            loggedOneSetID = loggedOneSet.id
            try store.logSet(loggedOneSet, toSessionItem: firstItemID)

            activeItemID = try #require(active.items.first?.id)
            try store.logSet(
                SetRecordData(order: 0, weight: Weight(kg: 60), reps: 8, completedAt: Fixture.epoch),
                toSessionItem: activeItemID
            )

            #expect(try store.loggedSessionsAwaitingAck().count == 2)

            // Drive the prune through the BurlySync seam, not the store API
            // directly — this is the integration point the gate names.
            // `active.id` rides along in the receipt too, proving the
            // .active refusal holds even when a transport (incorrectly)
            // includes it.
            let sync: SessionAckApplying = store
            try sync.apply(SessionAckReceipt(sessionIDs: [loggedOne.id, loggedTwo.id, active.id]))
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

        // Exercises, routines, and the last-performance digest are
        // untouched by the prune.
        #expect(try rowCount(Exercise.self, in: container) == 2)
        #expect(try reopened.exercise(id: bench.id) == bench)
        #expect(try reopened.exercise(id: row.id) == row)
        #expect(try rowCount(Routine.self, in: container) == 1)
        #expect(try reopened.routine(id: routine.id) == routine)
        let survivingDigest = try #require(try reopened.lastPerformance(exerciseID: bench.id))
        #expect(survivingDigest == digest)
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

    @Test("applying the exact same SessionAckReceipt twice is a no-op the second time: no throw, no additional deletions, store state identical")
    func replayingTheSameReceiptIsANoOp() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        var logged = Fixture.session(from: routine, startedAt: Fixture.epoch)
        logged.state = .logged
        let survivor = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        // `survivor` stays `.active` — a control that would catch a replay
        // that (incorrectly) re-walks and disturbs unrelated rows.
        try store.createSession(logged)
        try store.createSession(survivor)

        let sync: SessionAckApplying = store
        let receipt = SessionAckReceipt(sessionIDs: [logged.id])

        try sync.apply(receipt)
        #expect(try store.session(id: logged.id) == nil)
        let survivorAfterFirstApply = try #require(try store.session(id: survivor.id))
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)

        // Replay the identical receipt value. Must not throw — a session
        // already pruned reads as an "unknown id" to the second pass, and
        // that is the documented non-error case, not a failure.
        try sync.apply(receipt)
        #expect(try store.session(id: logged.id) == nil)
        let survivorAfterSecondApply = try #require(try store.session(id: survivor.id))
        #expect(survivorAfterSecondApply == survivorAfterFirstApply)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
    }

    @Test("a receipt naming the same id more than once prunes it exactly once, without throwing, and leaves other logged sessions untouched")
    func duplicateIDsWithinOneReceiptPruneOnce() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        var target = Fixture.session(from: routine, startedAt: Fixture.epoch)
        target.state = .logged
        var other = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        other.state = .logged
        try store.createSession(target)
        try store.createSession(other)

        let sync: SessionAckApplying = store
        // The duplicate entries name a session that, after the first
        // deletion, no longer exists — the second and third occurrences
        // must fall through the same "unknown id" `continue` as a genuine
        // miss, not throw or double-delete.
        try sync.apply(SessionAckReceipt(sessionIDs: [target.id, target.id, target.id]))

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

        var first = Fixture.session(from: routine, startedAt: Fixture.epoch)
        first.state = .logged
        var second = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        second.state = .logged
        try store.createSession(first)
        try store.createSession(second)

        let sync: SessionAckApplying = store
        try sync.apply(SessionAckReceipt(sessionIDs: [UUID(), first.id, second.id]))

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

        func seededStore() throws -> SwiftDataStore {
            let store = try makeStore(.watch)
            try store.createExercise(squat)
            try store.createRoutine(routine)
            var a = Fixture.session(id: idA, from: routine, startedAt: Fixture.epoch)
            a.state = .logged
            var b = Fixture.session(id: idB, from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
            b.state = .logged
            let survivor = Fixture.session(
                id: survivorID, from: routine, startedAt: Fixture.epoch.addingTimeInterval(120)
            )
            // `survivor` stays `.active`.
            try store.createSession(a)
            try store.createSession(b)
            try store.createSession(survivor)
            return store
        }

        let storeOne = try seededStore()
        let storeTwo = try seededStore()
        let syncOne: SessionAckApplying = storeOne
        let syncTwo: SessionAckApplying = storeTwo

        try syncOne.apply(SessionAckReceipt(sessionIDs: [idA, idB]))
        try syncTwo.apply(SessionAckReceipt(sessionIDs: [idB, idA]))

        #expect(try storeOne.session(id: idA) == nil)
        #expect(try storeOne.session(id: idB) == nil)
        #expect(try storeTwo.session(id: idA) == nil)
        #expect(try storeTwo.session(id: idB) == nil)
        #expect(try storeOne.loggedSessionsAwaitingAck().isEmpty)
        #expect(try storeTwo.loggedSessionsAwaitingAck().isEmpty)

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
