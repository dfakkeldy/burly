// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 store shape — "the watch never accumulates full history: after
// ack, delivered sessions are pruned from the watch store."
//
// Unit-level, in-memory coverage of the prune rule itself:
// `loggedSessionsAwaitingAck` (public) and the delivered-session portion of
// the sole whole-digest writer. Acknowledgements are never committed through
// a separate prune API: they arrive with a digest's performance entries and
// are persisted in that same transaction.

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

    @Test("a future watch journal schema is rejected without resetting its snapshot watermark")
    func futureJournalSchemaIsNotTreatedAsCorruptCache() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let seedContext = ModelContext(container)
        let payload = try JSONEncoder().encode(WatchSyncStateData(
            schemaVersion: 2,
            lastAppliedSnapshotVersion: 99
        ))
        seedContext.insert(WatchSyncJournal(payload: payload))
        try seedContext.save()

        let store = SwiftDataStore(container: container)
        #expect(throws: WatchSyncStateDecodingError.unsupportedSchemaVersion(2)) {
            try store.watchSyncState()
        }
    }

    @Test("a working-set replacement can move an item from a dropped routine to a retained routine")
    func replacementMovesItemFromDroppedRoutineToRetainedRoutine() throws {
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

        #expect(try store.replaceWatchWorkingSet(snapshot))
        #expect(try store.routine(id: removed.id) == nil)
        #expect(try store.routine(id: retained.id)?.items.map(\.id) == [reusedItemID])
    }

    @Test("a rejected working-set replacement cannot commit an omitted routine deletion through a later save")
    /// Guards F1's pending-mutation data-loss class: rejection must leave no
    /// staged deletion for an omitted routine that an unrelated later save can commit.
    func rejectedReplacementDoesNotLeakAnOmittedRoutineDeletionIntoALaterSave() throws {
        let store = try makeStore(.watch)
        let exercise = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let removed = Fixture.routine(name: "A", over: [exercise])
        let retained = Fixture.routine(name: "B", over: [exercise])
        try store.createExercise(exercise)
        try store.createRoutine(removed)
        try store.createRoutine(retained)

        // A is omitted (and would be deleted by a mutate-before-preflight
        // implementation), while B makes this payload reject independently.
        let rejected = BurlySnapshotPayloadDTO(version: 1, exercises: [], routines: [retained])
        #expect(throws: BurlyStoreError.missingExercise(exercise.id)) {
            try store.replaceWatchWorkingSet(rejected)
        }

        // This successful, unrelated save is what exposes a leaked pending mutation.
        try store.createExercise(Fixture.exercise(name: "Curl", muscleGroups: [.biceps]))

        #expect(try store.routine(id: removed.id) != nil)
        #expect(try store.routine(id: retained.id) != nil)
        #expect(try store.watchSyncState().lastAppliedSnapshotVersion == nil)
    }

    @Test("a duplicate routine-item id rejection cannot commit an omitted routine deletion through a later save")
    /// Guards F1's pending-mutation data-loss class at the deepest pre-mutation
    /// rejection. This uses the duplicate-id arm because it is the last rejection
    /// before the first staged mutation, so it constrains ordering; do not
    /// de-duplicate it with the earlier missing-exercise guard.
    func duplicateItemIDReplacementDoesNotLeakAnOmittedRoutineDeletionIntoALaterSave() throws {
        let store = try makeStore(.watch)
        let exercise = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let removed = Fixture.routine(name: "A", over: [exercise])
        let retained = Fixture.routine(name: "B", over: [exercise])
        let retainedOwner = Fixture.routine(name: "C", over: [exercise])
        try store.createExercise(exercise)
        try store.createRoutine(removed)
        try store.createRoutine(retained)
        try store.createRoutine(retainedOwner)

        // A is omitted (and would be deleted by a mutate-before-preflight
        // implementation). B reuses C's retained item ID, so that ID has not
        // been released and preflightRoutineItems must reject it as a duplicate.
        let reusedItemID = try #require(retainedOwner.items.first?.id)
        let rejectedRetained = RoutineData(
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
        let rejected = BurlySnapshotPayloadDTO(
            version: 1,
            exercises: [exercise],
            routines: [rejectedRetained, retainedOwner]
        )
        #expect(throws: BurlyStoreError.duplicateID(reusedItemID)) {
            try store.replaceWatchWorkingSet(rejected)
        }

        // This successful, unrelated save is what exposes a leaked pending mutation.
        try store.createExercise(Fixture.exercise(name: "Curl", muscleGroups: [.biceps]))

        #expect(try store.routine(id: removed.id) != nil)
        #expect(try store.routine(id: retained.id) != nil)
        #expect(try store.routine(id: retainedOwner.id) != nil)
        #expect(try store.watchSyncState().lastAppliedSnapshotVersion == nil)
    }

    @Test("a replacement into an empty watch store resolves a payload-introduced exercise")
    func replacementResolvesPayloadIntroducedExercise() throws {
        let store = try makeStore(.watch)
        let exercise = Fixture.exercise(name: "New custom", muscleGroups: [.biceps])
        let routine = Fixture.routine(name: "New routine", over: [exercise])
        let snapshot = BurlySnapshotPayloadDTO(version: 1, exercises: [exercise], routines: [routine])

        #expect(try store.replaceWatchWorkingSet(snapshot))
        #expect(try store.exercise(id: exercise.id) == exercise)
        #expect(try store.routine(id: routine.id)?.items.first?.exerciseID == exercise.id)
        #expect(try store.watchSyncState().lastAppliedSnapshotVersion == 1)
    }

    @Test("loggedSessionsAwaitingAck throws operationRequiresWatchStore on a phone-kind store")
    func awaitingAckIsWatchOnlyOnRead() throws {
        let store = try makeStore(.phone)
        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.loggedSessionsAwaitingAck()
        }
    }

    @Test("applyDigest throws operationRequiresWatchStore on a phone-kind store, and deletes nothing")
    func applyDigestIsWatchOnly() throws {
        let store = try makeStore(.phone)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        let session = Fixture.session(from: routine)
        try store.createExercise(squat)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.applyDigest(lastPerformance: [], ackedSessionIDs: [session.id])
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

    @Test("applyDigest removes an acked .logged session, cascading items and sets")
    func digestRemovesAckedLoggedSession() throws {
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

        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [session.id])

        #expect(try store.session(id: session.id) == nil)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
        // Untouched by the prune.
        #expect(try store.exercise(id: squat.id) == squat)
    }

    @Test("applyDigest leaves an .active session present even when acked")
    func digestLeavesActiveSessionPresent() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let active = Fixture.activeSession(from: routine)
        try store.saveActiveSession(active)

        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [active.id])

        let survivor = try #require(try store.session(id: active.id))
        #expect(survivor.state == .active)
    }

    @Test("applyDigest ignores an acknowledgement that names no session")
    func digestIgnoresUnknownID() throws {
        let store = try makeStore(.watch)
        // Should not throw for a bogus id — just a no-op for that entry.
        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [UUID()])
    }

    @Test("applyDigest is scoped: unacked logged sessions survive")
    func digestIsScopedToAckedIDs() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let acked = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let unacked = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try store.createSession(acked)
        try store.createSession(unacked)

        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [acked.id])

        #expect(try store.session(id: acked.id) == nil)
        #expect(try store.session(id: unacked.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [unacked.id])
    }
}
