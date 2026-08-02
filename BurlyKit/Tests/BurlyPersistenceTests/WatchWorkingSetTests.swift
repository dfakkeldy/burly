// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 store shape — "the watch never accumulates full history: after
// ack, delivered sessions are pruned from the watch store."
//
// Unit-level, in-memory coverage of the prune rule itself:
// `loggedSessionsAwaitingAck` (public) and `pruneDeliveredSessions`, which
// is module-internal now (m1-06 review round D — nothing outside the module
// may apply half a §5 digest) and reached here through `@testable`.
// `applyDigest` runs the identical rule as part of the whole payload, so
// pinning it once here keeps the digest tests about atomicity rather than
// about which ids are eligible. The disk-backed §1 acceptance #6 gate —
// prune through the BurlySync seam, cold-reopen, confirm absence — lives in
// AckSeamIntegrationTests.swift.

import Foundation
import SwiftData
import Testing
import BurlyCore
import BurlySync
@testable import BurlyPersistence

@MainActor
@Suite("§1 — watch working-set pruning API")
struct WatchWorkingSetTests {

    @Test("a corrupt watch journal recovers as rebuildable metadata and a valid digest still commits atomically")
    func corruptJournalRecoversWithoutStrandingOrDeletingAnOutboxSession() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let seedContext = ModelContext(container)
        seedContext.insert(WatchSyncJournal(payload: Data("not json".utf8)))
        try seedContext.save()

        let store = SwiftDataStore(container: container)
        let exercise = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [exercise])
        let session = Fixture.session(from: routine)
        try store.createExercise(exercise)
        try store.createRoutine(routine)
        try store.createSession(session)

        // Recovery makes the malformed blob an empty cache, not a thrown
        // rejection after the prune has already been staged.
        #expect(try store.watchSyncState() == WatchSyncStateData())
        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [session.id])
        #expect(try store.session(id: session.id) == nil)
        #expect(try store.watchSyncState().lastAckedSessionIDs == [session.id])
        #expect(try store.watchSyncState().schemaVersion == 1)
    }

    @Test("a rejected working-set replacement cannot leave an omitted routine staged for a later save")
    func rejectedReplacementLeavesNoStagedRoutineDelete() throws {
        let store = try makeStore(.watch)
        let exercise = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        try store.createExercise(exercise)
        let removed = Fixture.routine(
            name: "A",
            over: [exercise]
        )
        let retained = Fixture.routine(
            name: "B",
            over: [exercise]
        )
        try store.createRoutine(removed)
        try store.createRoutine(retained)
        let reusedItemID = try #require(removed.items.first?.id)
        let invalidRetained = RoutineData(
            id: retained.id,
            name: retained.name,
            orderIndex: retained.orderIndex,
            items: [RoutineItemData(
                id: reusedItemID,
                exerciseID: exercise.id,
                order: 0,
                defaultSetCount: 3
            )],
            updatedAt: retained.updatedAt,
            archivedAt: retained.archivedAt
        )
        let snapshot = BurlySnapshotPayloadDTO(
            version: 1,
            exercises: [exercise],
            routines: [invalidRetained]
        )

        #expect(throws: BurlyStoreError.duplicateID(reusedItemID)) {
            try store.replaceWatchWorkingSet(snapshot)
        }
        // A later successful save is the precise regression trigger: it
        // must not commit the delete of A that a mutate-before-preflight
        // implementation would have staged.
        try store.createExercise(Fixture.exercise(name: "Curl", muscleGroups: [.biceps]))
        #expect(try store.routine(id: removed.id) != nil)
        #expect(try store.routine(id: retained.id) != nil)
    }

    @Test("loggedSessionsAwaitingAck throws operationRequiresWatchStore on a phone-kind store")
    func awaitingAckIsWatchOnlyOnRead() throws {
        let store = try makeStore(.phone)
        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.loggedSessionsAwaitingAck()
        }
    }

    @Test("pruneDeliveredSessions throws operationRequiresWatchStore on a phone-kind store, and deletes nothing")
    func pruneIsWatchOnly() throws {
        let store = try makeStore(.phone)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        let session = Fixture.session(from: routine)
        try store.createExercise(squat)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.pruneDeliveredSessions(ackedIDs: [session.id])
        }
        #expect(try store.session(id: session.id) != nil)
    }

    @Test("loggedSessionsAwaitingAck returns only .logged sessions on a watch-kind store")
    func awaitingAckFiltersByState() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let logged = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(logged)
        // The live session goes in through the one path that can create one.
        let active = Fixture.activeSession(
            from: routine, startedAt: Fixture.epoch.addingTimeInterval(60)
        )
        try store.saveActiveSession(active)

        let awaiting = try store.loggedSessionsAwaitingAck()
        #expect(awaiting.count == 1)
        #expect(awaiting.first?.id == logged.id)
    }

    @Test("pruneDeliveredSessions removes an acked .logged session, cascading items and sets")
    func pruneRemovesAckedLoggedSession() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let empty = Fixture.session(from: routine)
        let session = empty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch),
            toItem: try #require(empty.items.first?.id)
        )
        try store.createSession(session)

        try store.pruneDeliveredSessions(ackedIDs: [session.id])

        #expect(try store.session(id: session.id) == nil)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
        // Untouched by the prune.
        #expect(try store.exercise(id: squat.id) == squat)
    }

    @Test("pruneDeliveredSessions refuses to prune an .active session even when acked")
    func pruneRefusesActiveSession() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let active = Fixture.activeSession(from: routine)
        try store.saveActiveSession(active)

        try store.pruneDeliveredSessions(ackedIDs: [active.id])

        let survivor = try #require(try store.session(id: active.id))
        #expect(survivor.state == .active)
    }

    @Test("pruneDeliveredSessions ignores an id that names no session")
    func pruneIgnoresUnknownID() throws {
        let store = try makeStore(.watch)
        // Should not throw for a bogus id — just a no-op for that entry.
        try store.pruneDeliveredSessions(ackedIDs: [UUID()])
    }

    @Test("pruneDeliveredSessions is scoped: unacked logged sessions survive")
    func pruneIsScopedToAckedIDs() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let acked = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let unacked = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try store.createSession(acked)
        try store.createSession(unacked)

        try store.pruneDeliveredSessions(ackedIDs: [acked.id])

        #expect(try store.session(id: acked.id) == nil)
        #expect(try store.session(id: unacked.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [unacked.id])
    }
}
