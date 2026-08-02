// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — `FileBackedPhoneSyncStatePersisting`: the JSON round-trip that
// lets `PhoneSyncMachine.State` (and the coordinator's daily-push
// bookkeeping) survive a relaunch without a schema change (house rule: no
// schema changes — see that type's file doc for why this cannot be a new
// `@Model`).
import Foundation
import Testing
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@Suite("m4-04 — FileBackedPhoneSyncStatePersisting: JSON round-trip")
struct PhoneSyncStatePersistingTests {

    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-phone-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "state.json", directoryHint: .notDirectory)
    }

    @Test("nothing saved yet reads back nil, not a throw")
    func loadWithNothingSavedReturnsNil() throws {
        let persisting = FileBackedPhoneSyncStatePersisting(url: makeTemporaryURL())
        #expect(try persisting.load() == nil)
    }

    @Test("a saved state round-trips byte-for-byte across a fresh instance — every field, not just the obvious ones")
    func savedStateRoundTripsAcrossAFreshInstance() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let idA = UUID()
        let idB = UUID()
        let machineState = BurlyPhoneSyncMachine.State(
            ackAge: [idA: 12_345, idB: 0],
            lastObservedNow: Date(timeIntervalSince1970: 1_700_000_000),
            pendingStoreConfirmations: [idA: BurlyPhoneSyncMachine.PendingIngest(revision: 3, age: 42)],
            latestSnapshotVersion: 7,
            lastTransferGeneration: 11,
            outstandingSnapshot: BurlyPhoneSyncMachine.SnapshotTransfer(version: 7, generation: 11)
        )
        let runtime = PhoneSyncRuntimeState(
            machineState: machineState,
            lastDailyPushAt: Date(timeIntervalSince1970: 1_699_999_000)
        )

        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)
        let reloaded = try FileBackedPhoneSyncStatePersisting(url: url).load()

        #expect(reloaded == runtime)
    }

    @Test("a state with no outstanding snapshot and no pending confirmations round-trips its empty collections correctly")
    func emptyCollectionsRoundTrip() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let runtime = PhoneSyncRuntimeState()
        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)
        let reloaded = try FileBackedPhoneSyncStatePersisting(url: url).load()

        #expect(reloaded == runtime)
        #expect(reloaded?.machineState.outstandingSnapshot == nil)
        #expect(reloaded?.machineState.pendingStoreConfirmations.isEmpty == true)
        #expect(reloaded?.lastDailyPushAt == nil)
    }

    @Test("a second save overwrites the first — latest-wins, not accumulating rows in some hidden log")
    func secondSaveOverwritesTheFirst() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 1)
        ))
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 2)
        ))

        let reloaded = try persisting.load()
        #expect(reloaded?.machineState.latestSnapshotVersion == 2)
    }

    @Test("the coordinator's own state survives being reconstructed from a freshly loaded persistence file")
    @MainActor
    func coordinatorStateSurvivesReconstruction() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)

        do {
            let persisting = FileBackedPhoneSyncStatePersisting(url: url)
            let coordinator = PhoneSyncCoordinator(
                store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
                statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
            )
            try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: session, needsNamingExercises: []))
        }

        // A fresh coordinator, as a relaunch would construct one, loading
        // from the same file.
        let reloadedPersisting = FileBackedPhoneSyncStatePersisting(url: url)
        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: reloadedPersisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.currentMachineState.ackAge.keys.contains(session.id))
    }
}
