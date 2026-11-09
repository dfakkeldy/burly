// SPDX-License-Identifier: MIT
// Phone history edits that a later §5 delivery must not undo, driven
// through the real `PhoneSyncCoordinator` against a real `SwiftDataStore`:
//
// - A session the user deleted on the phone (`deleteLoggedSession`) and the
//   watch then sends again — it keeps a session until a digest acks it — is
//   acked so the watch prunes it, and never re-inserted. Also after the
//   phone's 30-day ack window has let go of the original ack.
// - §6 acceptance #4: a naming-queue merge survives a re-delivery of the
//   session that introduced the placeholder.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("Phone history delete and naming merge survive a §5 re-delivery")
struct HistoryDeletionSyncTests {

    private struct Harness {
        let store: SwiftDataStore
        let clock: TestClock
        let scheduler: ManualTriggerScheduler
        let digestPublisher: FakeDigestPublisher
        let coordinator: PhoneSyncCoordinator
    }

    private func makeHarness() throws -> Harness {
        let clock = TestClock()
        let store = try makePhoneStore(clock: clock)
        let scheduler = ManualTriggerScheduler()
        let digestPublisher = FakeDigestPublisher()
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: FakeTransport(),
            digestPublisher: digestPublisher,
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: clock,
            scheduler: scheduler
        )
        return Harness(store: store, clock: clock, scheduler: scheduler, digestPublisher: digestPublisher, coordinator: coordinator)
    }

    /// Fires the one pending digest countdown and waits for its publish.
    private func publishPendingDigest(_ harness: Harness) async {
        await harness.scheduler.waitUntilWaiting(count: 1)
        harness.scheduler.advance(by: .seconds(5))
        await harness.coordinator.drainPendingDebounces()
    }

    /// A logged bench session with one working set, as the watch sends it.
    private func benchPayload(in store: SwiftDataStore) throws -> (BurlySessionPayloadDTO, ExerciseData) {
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let empty = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let itemID = try #require(empty.items.first?.id)
        let session = empty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 80), reps: 5, completedAt: Fixture.epoch),
            toItem: itemID
        )
        return (BurlySessionPayloadDTO(session: session, needsNamingExercises: []), bench)
    }

    // MARK: - Delete

    @Test("a deleted session the watch sends again is acked, not re-inserted, and the digest acks it without its numbers")
    func deletedSessionRedeliveryIsAckedNotReinserted() async throws {
        let harness = try makeHarness()
        let (payload, bench) = try benchPayload(in: harness.store)
        let sessionID = payload.session.id

        try await harness.coordinator.sessionReceived(payload)
        await publishPendingDigest(harness)
        #expect(try harness.store.session(id: sessionID) != nil)

        // The user deletes it on the phone before the watch has seen the
        // digest that acks it, so the watch still holds it and re-sends.
        try harness.store.deleteLoggedSession(id: sessionID)
        try await harness.coordinator.sessionReceived(payload)

        #expect(try harness.store.session(id: sessionID) == nil, "the delete must stick")
        #expect(try harness.store.loggedSessionCount() == 0)
        let state = harness.coordinator.currentMachineState
        #expect(state.ackAge.keys.contains(sessionID), "the watch is owed the ack so it prunes its copy and stops re-sending")
        #expect(state.pendingStoreConfirmations.isEmpty)

        await publishPendingDigest(harness)
        let digest = try #require(await harness.digestPublisher.published.last)
        #expect(digest.ackedSessionIDs == [sessionID])
        // The digest is derived from history that no longer holds the
        // session: the watch's "last time" for bench must not show it.
        #expect(digest.lastPerformance.contains { $0.exerciseID == bench.id } == false)
    }

    @Test("a re-delivery after the 30-day ack window still cannot bring a deleted session back, and earns a fresh ack")
    func deletedSessionStaysDeletedAfterTheAckAgesOut() async throws {
        let harness = try makeHarness()
        let (payload, _) = try benchPayload(in: harness.store)
        let sessionID = payload.session.id

        try await harness.coordinator.sessionReceived(payload)
        try harness.store.deleteLoggedSession(id: sessionID)

        // A watch that stayed offline past §5's 30-day retention. Any
        // event ages the ack set first; history-changed is the one the app
        // itself sends after a delete.
        harness.clock.advance(by: 31 * 24 * 60 * 60)
        try await harness.coordinator.historyDidChange()
        #expect(harness.coordinator.currentMachineState.ackAge.keys.contains(sessionID) == false, "precondition: the original ack has aged out")

        try await harness.coordinator.sessionReceived(payload)

        #expect(try harness.store.session(id: sessionID) == nil, "the tombstone, not the ack, is what keeps it deleted")
        #expect(harness.coordinator.currentMachineState.ackAge.keys.contains(sessionID))
    }

    @Test("item 4 — a delete between the advisory lookup and the verification re-drives to a settled no-op, never a re-insert")
    func verificationAfterAHistoryDeleteDoesNotResurrect() async throws {
        let harness = try makeHarness()
        let (payload, _) = try benchPayload(in: harness.store)
        let sessionID = payload.session.id
        try await harness.coordinator.sessionReceived(payload)

        // Same seam as PhoneSessionIngestTests' item-4 pin, but the row is
        // gone through the user's delete rather than the raw cascade.
        try harness.store.deleteLoggedSession(id: sessionID)
        try await harness.coordinator.execute(
            [.confirmSessionStored(id: sessionID, revision: payload.session.revision)],
            originalPayload: payload
        )

        #expect(try harness.store.session(id: sessionID) == nil)
        #expect(harness.coordinator.currentMachineState.ackAge.keys.contains(sessionID))
        #expect(harness.coordinator.currentMachineState.pendingStoreConfirmations.isEmpty)
    }

    // MARK: - Naming merge (§6 acceptance #4)

    @Test("§6 #4 — a merged placeholder stays merged when the session that introduced it is delivered again")
    func namingMergeSurvivesARedelivery() async throws {
        let harness = try makeHarness()
        let store = harness.store
        let row = Fixture.exercise(name: "Barbell Row", muscleGroups: [.upperBack, .lats])
        try store.createExercise(row)
        let placeholder = Fixture.exercise(name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true)

        let session = SessionData(
            startedAt: Fixture.epoch,
            endedAt: Fixture.epoch.addingTimeInterval(1800),
            state: .logged,
            origin: .live,
            items: [SessionItemData(
                exerciseID: placeholder.id,
                order: 0,
                sets: [SetRecordData(order: 0, weight: Weight(kg: 60), reps: 8, completedAt: Fixture.epoch)]
            )]
        )
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [placeholder])

        try await harness.coordinator.sessionReceived(payload)
        #expect(try store.exercise(id: placeholder.id)?.needsNaming == true)

        // The naming queue's Merge: history moves onto the real exercise.
        try store.mergePlaceholderExercise(id: placeholder.id, into: row.id, at: Fixture.epoch.addingTimeInterval(3600))

        // The watch, which had not yet seen the ack, sends the same payload
        // again — the placeholder embedded as it first knew it.
        try await harness.coordinator.sessionReceived(payload)

        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items.map(\.exerciseID) == [row.id], "the re-delivery must not re-point history at the placeholder")
        #expect(stored.revision == session.revision)
        let storedPlaceholder = try #require(try store.exercise(id: placeholder.id))
        #expect(storedPlaceholder.archivedAt == Fixture.epoch.addingTimeInterval(3600), "the placeholder stays archived")
        // The phone's naming queue is the unarchived needsNaming rows.
        let queue = try store.exercises(includingArchived: true).filter { $0.needsNaming && $0.archivedAt == nil }
        #expect(queue.isEmpty, "a merged placeholder must not come back to the naming queue")
        #expect(harness.coordinator.currentMachineState.ackAge.keys.contains(session.id))

        // The digest the watch will read credits the merge destination.
        let digest = try SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: 0,
            ackedSessionIDs: Set(harness.coordinator.currentMachineState.ackAge.keys)
        )
        #expect(digest.lastPerformance.map(\.exerciseID) == [row.id])
    }
}
