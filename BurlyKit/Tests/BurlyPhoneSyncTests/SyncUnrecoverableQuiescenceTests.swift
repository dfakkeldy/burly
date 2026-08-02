// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 review round 3, §1 — the unrecoverable state must be PREVENTED from
// transmitting, not merely detected: after a load that throws
// `PhoneSyncStateUnrecoverableError` (both the primary state file and the
// high-water log untrustworthy), the coordinator's zeroed fallback `State`
// must never reach the transport or the digest publisher. Rounds 1 and 2
// surfaced the condition (`syncStateUnrecoverable`) but left every push
// trigger operational — a corrupted phone would retransmit reused
// `(version, generation)` identities and regress the watch below its true
// version. These pins prove the pushes are actually disabled (the round-3
// review's named coverage gap), and pin the one legitimate exit:
// `resetSyncStateForRePair()`.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("m4-04 — round 3, §1: unrecoverable sync state quiesces every push")
struct SyncUnrecoverableQuiescenceTests {

    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-quiescence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "state.json", directoryHint: .notDirectory)
    }

    private func highWaterURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("highwater.jsonl")
    }

    /// Persists a real prior identity (version 7, generation 11 — the
    /// review's concrete scenario), then corrupts BOTH files so the next
    /// load is unrecoverable.
    private func makeCorruptedPersisting(url: URL) throws -> FileBackedPhoneSyncStatePersisting {
        let hwURL = highWaterURL(for: url)
        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 7, lastTransferGeneration: 11)
        ))
        try Data("not json {{{".utf8).write(to: url)
        try Data("also not json {{{".utf8).write(to: hwURL)
        return persisting
    }

    @Test("the review's pin: files held (version 7, generation 11), the load is unrecoverable — applicationDidLaunch and EVERY other public trigger transmit NOTHING, and the flag is observable")
    func unrecoverableLoadDisablesEveryPublicPushTrigger() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = try makeCorruptedPersisting(url: url)

        // A store with real content, so a snapshot push WOULD have
        // something to build and transmit if the gates ever leaked.
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        try store.createRoutine(routine)

        let transport = FakeTransport()
        let digestPublisher = FakeDigestPublisher()
        let scheduler = ManualTriggerScheduler()
        let clock = TestClock()
        let coordinator = PhoneSyncCoordinator(
            store: store, transport: transport, digestPublisher: digestPublisher,
            statePersisting: persisting, clock: clock, scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1))
        )

        #expect(coordinator.syncStateUnrecoverable, "the unrecoverable load must be observable")

        // Every public push/trigger/ingest entry point, exhaustively —
        // the round-3 audit list: app launch, install flip, daily push,
        // catalog change, history change (digest publish), session ingest,
        // and the transport's own completion callback.
        try await coordinator.applicationDidLaunch()
        try await coordinator.watchAppInstalledDidChange(true)
        try await coordinator.dailyPushIfDue()
        try await coordinator.historyDidChange()
        try await coordinator.snapshotTransferFinished(version: 7, generation: 11)
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: session, needsNamingExercises: []))
        await coordinator.catalogDidChange()

        // The catalog gate must not even schedule a debounce countdown —
        // nothing may fire later, either.
        await scheduler.settle()
        #expect(scheduler.pendingCount == 0, "no debounce countdown may exist while unrecoverable")
        // Belt and braces: advance far past every window and drain anyway.
        scheduler.advance(by: .seconds(60))
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.isEmpty, "the transport must have received NOTHING — no reused (version, generation) may leave the device")
        #expect(await transport.cancellations.isEmpty, "not even a cancel may be issued from the zeroed state")
        #expect(await digestPublisher.published.isEmpty, "the digest publisher is a transmission too — nothing may be published")
        #expect(coordinator.currentMachineState == BurlyPhoneSyncMachine.State(), "no machine event ran — the zeroed state never moved (no generation 1, no version bump)")
        #expect(try store.session(id: session.id) == nil, "the quiesced ingest is a full no-op — the watch's own durable copy re-delivers after re-pair")
        #expect(coordinator.syncStateUnrecoverable, "still surfaced after every attempted trigger")
    }

    @Test("the daily-push gate also refuses when a full interval has elapsed — quiescence is not just 'not due yet'")
    func dailyPushStaysQuiescentEvenWhenDue() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = try makeCorruptedPersisting(url: url)

        let transport = FakeTransport()
        let clock = TestClock()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: clock, scheduler: ManualTriggerScheduler()
        )
        #expect(coordinator.syncStateUnrecoverable)

        clock.advance(by: 48 * 60 * 60) // two full daily intervals
        try await coordinator.dailyPushIfDue()
        #expect(await transport.transmissions.isEmpty)
    }

    @Test("resetSyncStateForRePair persists a fresh identity domain, lifts the gates, and a relaunch loads it cleanly with no recovery flags")
    func explicitResetMintsAFreshIdentityDomain() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = try makeCorruptedPersisting(url: url)

        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = PhoneSyncCoordinator(
            store: store, transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(coordinator.syncStateUnrecoverable)

        try coordinator.resetSyncStateForRePair()
        #expect(coordinator.syncStateUnrecoverable == false)
        #expect(coordinator.recoveredFromCorruptState == false)
        #expect(coordinator.currentMachineState == BurlyPhoneSyncMachine.State())

        // The fresh domain works: pushes resume, restarting the generation
        // line at 1 — a line the re-paired (reset) watch treats as fresh.
        try await coordinator.applicationDidLaunch()
        #expect(await transport.transmissions.map(\.generation) == [1])

        // And it is durable: a relaunch over the same files is a clean
        // load — no corruption recovery, no unrecoverable flag, and the
        // persisted identity continues from where the reset domain got to.
        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: highWaterURL(for: url)),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.syncStateUnrecoverable == false)
        #expect(relaunched.recoveredFromCorruptState == false)
        #expect(relaunched.currentMachineState.lastTransferGeneration == 1)
    }

    @Test("a reset whose persistence fails stays fully quiescent — the gates never lift on an identity domain that is not durably on disk")
    func failedResetPersistenceKeepsTheCoordinatorQuiescent() async throws {
        final class UnrecoverableWithFailingSave: PhoneSyncStatePersisting, @unchecked Sendable {
            struct SaveFailure: Error, Equatable {}
            func load() throws -> PhoneSyncLoadResult? { throw PhoneSyncStateUnrecoverableError() }
            func save(_ state: PhoneSyncRuntimeState) throws { throw SaveFailure() }
        }

        let transport = FakeTransport()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: UnrecoverableWithFailingSave(),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(coordinator.syncStateUnrecoverable)

        #expect(throws: UnrecoverableWithFailingSave.SaveFailure()) {
            try coordinator.resetSyncStateForRePair()
        }
        #expect(coordinator.syncStateUnrecoverable, "a failed persist must leave the flag set")

        try await coordinator.applicationDidLaunch()
        #expect(await transport.transmissions.isEmpty, "still quiescent after the failed reset")
    }

    @Test("reset is a no-op on a healthy coordinator — it can never be misused to regress a live identity line")
    func resetIsANoOpWhenHealthy() async throws {
        let persisting = InMemoryPhoneSyncStatePersisting(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 4, lastTransferGeneration: 9)
        ))
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(coordinator.syncStateUnrecoverable == false)

        try coordinator.resetSyncStateForRePair()

        #expect(coordinator.currentMachineState.latestSnapshotVersion == 4, "a healthy identity line must be untouched")
        #expect(coordinator.currentMachineState.lastTransferGeneration == 9)
        #expect(try persisting.load()?.runtimeState.machineState.lastTransferGeneration == 9, "and nothing was persisted over it")
    }
}
