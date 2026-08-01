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
}
