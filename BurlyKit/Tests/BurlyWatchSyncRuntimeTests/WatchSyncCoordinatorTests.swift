import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
@testable import BurlyWatchSyncRuntime

@Suite("§5 concrete watch coordinator")
struct WatchSyncCoordinatorTests {
    @Test("a received snapshot with a new referenced exercise applies and advances its durable version")
    @MainActor
    func receivedSnapshotAppliesToEmptyWatchStore() throws {
        let store = try SwiftDataStore(kind: .watch, at: .inMemory)
        let exercise = ExerciseData(name: "Custom", muscleGroups: [], origin: .custom)
        let routine = RoutineData(name: "R", orderIndex: 0, items: [RoutineItemData(exerciseID: exercise.id, order: 0, defaultSetCount: 1)], updatedAt: .now)
        let snapshot = BurlySnapshotPayloadDTO(version: 7, exercises: [exercise], routines: [routine])
        let coordinator = try WatchSyncCoordinator(store: store)

        let data = try BurlySyncEnvelope(payload: .snapshot(snapshot)).encodedData()
        #expect(try coordinator.receive(data) == .appliedSnapshot(version: 7))
        #expect(try store.exercise(id: exercise.id) == exercise)
        #expect(try store.routine(id: routine.id)?.items.first?.exerciseID == exercise.id)
        #expect(try store.watchSyncState().lastAppliedSnapshotVersion == 7)
    }

    @Test("a delivered-and-acked session is pruned by the routed digest")
    @MainActor
    func deliveredAndAckedSessionIsPruned() throws {
        let store = try SwiftDataStore(kind: .watch, at: .inMemory)
        let exercise = ExerciseData(name: "Custom", muscleGroups: [], origin: .custom, needsNaming: true)
        try store.createExercise(exercise)
        let routine = RoutineData(name: "R", orderIndex: 0, items: [RoutineItemData(exerciseID: exercise.id, order: 0, defaultSetCount: 1)], updatedAt: .now)
        try store.createRoutine(routine)
        let session = SessionData(routineID: routine.id, routineName: routine.name, startedAt: .now, endedAt: .now, state: .logged, origin: .live, items: [SessionItemData(exerciseID: exercise.id, order: 0)])
        try store.createSession(session)
        let coordinator = try WatchSyncCoordinator(store: store)

        let sent = try coordinator.completedSession(id: session.id)
        #expect(sent.outbound.count == 1)
        #expect(sent.outbound[0].id == session.id)
        #expect(sent.failedOutboundSessionIDs.isEmpty)
        let sessionEnvelope = try #require(BurlySyncEnvelope.decode(sent.outbound[0].envelope).envelope)
        guard case let .session(payload) = sessionEnvelope.payload else { Issue.record("expected session"); return }
        #expect(payload.needsNamingExercises == [exercise])

        let digest = BurlySyncEnvelope(payload: .digest(BurlyDigestPayloadDTO(snapshotVersion: 0, lastPerformance: [], ackedSessionIDs: [session.id])))
        #expect(try coordinator.receive(digest.encodedData()) == .appliedDigest)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
        #expect(try store.session(id: session.id) == nil)
        #expect(try store.watchSyncState().lastAckedSessionIDs == [session.id])
    }

    @Test("an ack/prune survives a cold reopen while an unacked completion remains ordered in the outbox")
    @MainActor
    func coldReopenRetainsOnlyUnackedOutboxEntry() throws {
        let url = URL.temporaryDirectory.appending(path: "burly-watch-sync-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        }
        let exercise = ExerciseData(name: "Custom", muscleGroups: [], origin: .custom, needsNaming: true)
        let routine = RoutineData(name: "R", orderIndex: 0, items: [RoutineItemData(exerciseID: exercise.id, order: 0, defaultSetCount: 1)], updatedAt: .now)
        let delivered = SessionData(routineID: routine.id, routineName: routine.name, startedAt: .now, endedAt: .now, state: .logged, origin: .live, items: [SessionItemData(exerciseID: exercise.id, order: 0)])
        let pending = SessionData(routineID: routine.id, routineName: routine.name, startedAt: .now.addingTimeInterval(1), endedAt: .now.addingTimeInterval(1), state: .logged, origin: .live, items: [SessionItemData(exerciseID: exercise.id, order: 0)])
        let laterPending = SessionData(routineID: routine.id, routineName: routine.name, startedAt: .now.addingTimeInterval(2), endedAt: .now.addingTimeInterval(2), state: .logged, origin: .live, items: [SessionItemData(exerciseID: exercise.id, order: 0)])

        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url))
            try store.createExercise(exercise)
            try store.createRoutine(routine)
            try store.createSession(delivered)
            try store.createSession(pending)
            try store.createSession(laterPending)
            let coordinator = try WatchSyncCoordinator(store: store)
            let digest = BurlySyncEnvelope(payload: .digest(BurlyDigestPayloadDTO(snapshotVersion: 0, lastPerformance: [], ackedSessionIDs: [delivered.id])))
            #expect(try coordinator.receive(digest.encodedData()) == .appliedDigest)
            #expect(try store.watchSyncState().lastAckedSessionIDs == [delivered.id])
        }

        let reopened = try SwiftDataStore(kind: .watch, at: .file(url))
        #expect(try reopened.watchSyncState().lastAckedSessionIDs == [delivered.id])
        #expect(try reopened.session(id: delivered.id) == nil)
        #expect(try reopened.session(id: pending.id) != nil)
        let coordinator = try WatchSyncCoordinator(store: reopened)
        let retried = try coordinator.activated()
        #expect(retried.outbound.map(\.id) == [pending.id, laterPending.id])
    }

    @Test("placeholder embedding is stable by exercise id across rehydration")
    @MainActor
    func placeholderEmbeddingSortsByExerciseID() throws {
        let store = try SwiftDataStore(kind: .watch, at: .inMemory)
        let high = ExerciseData(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!, name: "High", muscleGroups: [], origin: .custom, needsNaming: true)
        let low = ExerciseData(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Low", muscleGroups: [], origin: .custom, needsNaming: true)
        try store.createExercise(high)
        try store.createExercise(low)
        let session = SessionData(startedAt: .now, endedAt: .now, state: .logged, origin: .live, items: [
            SessionItemData(exerciseID: high.id, order: 0),
            SessionItemData(exerciseID: low.id, order: 1)
        ])
        try store.createSession(session)

        let first = try #require(try store.watchOutboxPayload(sessionID: session.id))
        let coordinator = try WatchSyncCoordinator(store: store)
        let retransmission = try coordinator.activated()
        let envelope = try #require(BurlySyncEnvelope.decode(retransmission.outbound[0].envelope).envelope)
        guard case let .session(second) = envelope.payload else { Issue.record("expected session"); return }
        #expect(first.needsNamingExercises.map(\.id) == [low.id, high.id])
        #expect(second.needsNamingExercises == first.needsNamingExercises)
    }
}

private extension BurlySyncDecodeResult {
    var envelope: BurlySyncEnvelope? {
        guard case let .decoded(envelope) = self else { return nil }
        return envelope
    }
}
