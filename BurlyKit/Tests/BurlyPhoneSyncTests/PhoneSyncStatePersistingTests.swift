// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("m4-08 — FileBackedPhoneSyncStatePersisting journal")
struct PhoneSyncStatePersistingTests {
    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-phone-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "state.jsonl", directoryHint: .notDirectory)
    }

    @Test("a saved state round-trips across a fresh instance with every field intact")
    func savedStateRoundTripsAcrossAFreshInstance() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let idA = UUID()
        let idB = UUID()
        let runtime = PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(
                ackAge: [idA: 12_345, idB: 0],
                lastObservedNow: Date(timeIntervalSince1970: 1_700_000_000),
                pendingStoreConfirmations: [idA: .init(revision: 3, age: 42)],
                latestSnapshotVersion: 7,
                lastTransferGeneration: 11,
                outstandingSnapshot: .init(version: 7, generation: 11)
            ),
            lastDailyPushAt: Date(timeIntervalSince1970: 1_699_999_000)
        )

        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)
        let reloaded = try FileBackedPhoneSyncStatePersisting(url: url).load()

        #expect(reloaded?.runtimeState == runtime)
        #expect(reloaded?.recoveredFromCorruption == false)
    }

    @Test("empty collections and optional fields round-trip")
    func emptyCollectionsRoundTrip() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let runtime = PhoneSyncRuntimeState()
        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)

        let reloaded = try #require(try FileBackedPhoneSyncStatePersisting(url: url).load())
        #expect(reloaded.runtimeState == runtime)
        #expect(reloaded.runtimeState.machineState.outstandingSnapshot == nil)
        #expect(reloaded.runtimeState.machineState.pendingStoreConfirmations.isEmpty)
        #expect(reloaded.runtimeState.lastDailyPushAt == nil)
    }

    @Test("the newest record supplies full state while identities remain max-derived")
    func newestRecordSuppliesFullStateAndMaxima() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldID = UUID()
        let newID = UUID()
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            ackAge: [oldID: 1], latestSnapshotVersion: 9, lastTransferGeneration: 2
        )))
        try persisting.save(.init(machineState: .init(
            ackAge: [newID: 3], latestSnapshotVersion: 4, lastTransferGeneration: 8
        )))

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.machineState.ackAge == [newID: 3])
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 9)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 8)
    }

    @Test("the coordinator reconstructs its state from the journal")
    func coordinatorStateSurvivesReconstruction() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let session = Fixture.session(from: Fixture.routine(over: [bench]), startedAt: Fixture.epoch)

        do {
            let coordinator = PhoneSyncCoordinator(
                store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
                statePersisting: FileBackedPhoneSyncStatePersisting(url: url),
                clock: TestClock(), scheduler: ManualTriggerScheduler()
            )
            try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: session, needsNamingExercises: []))
        }

        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: FileBackedPhoneSyncStatePersisting(url: url),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.currentMachineState.ackAge.keys.contains(session.id))
        #expect(relaunched.recoveredFromCorruptState == false)
    }

    @Test("Snapshot validation throws for every hostile field instead of trapping")
    func makeRuntimeStateThrowsForEveryInvalidField() throws {
        let sessionID = UUID()
        #expect(throws: PhoneSyncStateCorruptionError.negativeSnapshotVersion(-1)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: -1, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.snapshotVersionTooLarge(Int.max)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: Int.max, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativeTransferGeneration(-2)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: 0, lastTransferGeneration: -2
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.transferGenerationTooLarge(Int.max)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: 0, lastTransferGeneration: Int.max
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativeAckAge(sessionID: sessionID, age: -5)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                ackAge: [sessionID: -5], latestSnapshotVersion: 0, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativePendingAge(sessionID: sessionID, age: -3)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                pendingRevisions: [sessionID: 1], pendingAges: [sessionID: -3],
                latestSnapshotVersion: 0, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
    }

    @Test("save refuses an out-of-range snapshot version before changing the journal")
    func saveRefusesOutOfRangeSnapshotVersion() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(latestSnapshotVersion: 3, lastTransferGeneration: 2)))
        let bytesBefore = try Data(contentsOf: url)

        #expect(throws: PhoneSyncIdentityOverflowError.snapshotVersionOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try persisting.save(.init(machineState: .init(
                latestSnapshotVersion: maximumPhoneSyncIdentity + 1,
                lastTransferGeneration: 2
            )))
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(try persisting.load()?.runtimeState.machineState.latestSnapshotVersion == 3)
    }

    @Test("save refuses an out-of-range generation in file-backed and in-memory conformers")
    func saveRefusesOutOfRangeTransferGenerationInBothConformers() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outOfRange = PhoneSyncRuntimeState(machineState: .init(
            latestSnapshotVersion: 1,
            lastTransferGeneration: maximumPhoneSyncIdentity + 1
        ))
        let fileBacked = FileBackedPhoneSyncStatePersisting(url: url)
        #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try fileBacked.save(outOfRange)
        }
        let inMemory = InMemoryPhoneSyncStatePersisting()
        #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try inMemory.save(outOfRange)
        }
        #expect(try inMemory.load() == nil)
    }

    @Test("the identity ceiling is inclusive across save and load")
    func stateExactlyAtTheCeilingRoundTrips() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            latestSnapshotVersion: maximumPhoneSyncIdentity,
            lastTransferGeneration: maximumPhoneSyncIdentity
        )))
        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == maximumPhoneSyncIdentity)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == maximumPhoneSyncIdentity)
    }

    @Test("an increment past the ceiling is neither transmitted nor persisted")
    func incrementPastCeilingNeverReachesTransportOrDisk() async throws {
        let persisting = InMemoryPhoneSyncStatePersisting(.init(machineState: .init(
            latestSnapshotVersion: 1,
            lastTransferGeneration: maximumPhoneSyncIdentity
        )))
        let transport = FakeTransport()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        await #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try await coordinator.applicationDidLaunch()
        }
        #expect(await transport.transmissions.isEmpty)
        #expect(try persisting.load()?.runtimeState.machineState.lastTransferGeneration == maximumPhoneSyncIdentity)
    }

    @Test("a catalog edit at the ceiling surfaces overflow and transmits nothing")
    func catalogEditAtVersionCeilingSurfacesOverflowWithoutTransmitting() async throws {
        let persisting = InMemoryPhoneSyncStatePersisting(.init(machineState: .init(
            latestSnapshotVersion: maximumPhoneSyncIdentity,
            lastTransferGeneration: 1
        )))
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: scheduler,
            configuration: .init(
                catalogEditDebounce: .seconds(1),
                digestPublishDebounce: .seconds(1),
                catalogPushRetryCount: 0
            )
        )
        await coordinator.catalogDidChange()
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await coordinator.drainPendingDebounces()
        #expect(await transport.transmissions.isEmpty)
        #expect(coordinator.lastCatalogPushFailure as? PhoneSyncIdentityOverflowError != nil)
        #expect(try persisting.load()?.runtimeState.machineState.latestSnapshotVersion == maximumPhoneSyncIdentity)
    }

    @Test("the coordinator surfaces an unrecoverable journal and constructs safely")
    func coordinatorSurfacesSyncStateUnrecoverable() async throws {
        struct AlwaysUnrecoverableStatePersisting: PhoneSyncStatePersisting {
            func load() throws -> PhoneSyncLoadResult? { throw PhoneSyncStateUnrecoverableError() }
            func save(_ state: PhoneSyncRuntimeState) throws {}
            func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {}
        }
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: AlwaysUnrecoverableStatePersisting(),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(coordinator.syncStateUnrecoverable)
        #expect(coordinator.recoveredFromCorruptState)
        #expect(coordinator.currentMachineState == BurlyPhoneSyncMachine.State())
    }

    @Test("a valid older record keeps identity progression monotonic across a corrupt append and relaunch")
    func identityNeverRegressesAcrossACorruptionAndRelaunch() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try makePhoneStore()
        var lastGeneration = 0
        do {
            let coordinator = PhoneSyncCoordinator(
                store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
                statePersisting: FileBackedPhoneSyncStatePersisting(url: url),
                clock: TestClock(), scheduler: ManualTriggerScheduler()
            )
            try await coordinator.applicationDidLaunch()
            try await coordinator.applicationDidLaunch()
            try await coordinator.applicationDidLaunch()
            lastGeneration = coordinator.currentMachineState.lastTransferGeneration
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{torn".utf8))
        try handle.close()

        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: FileBackedPhoneSyncStatePersisting(url: url),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.recoveredFromCorruptState)
        #expect(relaunched.currentMachineState.lastTransferGeneration == lastGeneration)
        try await relaunched.applicationDidLaunch()
        #expect(relaunched.currentMachineState.lastTransferGeneration == lastGeneration + 1)
    }

    @Test("ordinary save cannot make a present zero-valid-line journal operational")
    func saveRefusesAnUnrecoverableJournal() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt\n".utf8).write(to: url)
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        #expect(throws: PhoneSyncStateUnrecoverableError()) {
            try persisting.save(PhoneSyncRuntimeState())
        }
        #expect(try Data(contentsOf: url) == Data("corrupt\n".utf8))
    }
}
