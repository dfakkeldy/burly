import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
@testable import BurlyWatchSyncRuntime

@Suite("§5 concrete watch coordinator")
struct WatchSyncCoordinatorTests {
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
        #expect(sent.count == 1)
        let sessionEnvelope = try #require(BurlySyncEnvelope.decode(sent[0]).envelope)
        guard case let .session(payload) = sessionEnvelope.payload else { Issue.record("expected session"); return }
        #expect(payload.needsNamingExercises == [exercise])

        let digest = BurlySyncEnvelope(payload: .digest(BurlyDigestPayloadDTO(snapshotVersion: 0, lastPerformance: [], ackedSessionIDs: [session.id])))
        #expect(try coordinator.receive(digest.encodedData()) == .appliedDigest)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
        #expect(try store.session(id: session.id) == nil)
    }
}

private extension BurlySyncDecodeResult {
    var envelope: BurlySyncEnvelope? {
        guard case let .decoded(envelope) = self else { return nil }
        return envelope
    }
}
