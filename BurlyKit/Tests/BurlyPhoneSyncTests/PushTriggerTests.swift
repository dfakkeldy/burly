// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — spec §5's push triggers: "snapshot on app launch, on any routine/
// catalog edit (debounced 5 s), when isWatchAppInstalled flips true, and
// daily. ... Digest is refreshed whenever history changes ... A newer
// snapshot cancels any outstanding snapshot transfer." Every timing
// assertion here runs under `ManualTriggerScheduler`/`TestClock` — no real
// sleeping, no wall-clock jitter, exact boundaries asserted directly.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
@testable import BurlyPhoneSync

@MainActor
@Suite("m4-04 — PhoneSyncCoordinator: push triggers")
struct PushTriggerTests {

    private func makeCoordinator(
        store: any BurlyStore,
        transport: FakeTransport,
        scheduler: ManualTriggerScheduler,
        clock: TestClock = TestClock(),
        configuration: PhoneSyncCoordinator.Configuration = .init()
    ) -> PhoneSyncCoordinator {
        PhoneSyncCoordinator(
            store: store,
            transport: transport,
            digestPublisher: FakeDigestPublisher(),
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: clock,
            scheduler: scheduler,
            configuration: configuration
        )
    }

    // MARK: - App launch

    @Test("app launch transmits a snapshot immediately, no debounce")
    func applicationLaunchTransmitsImmediately() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        try await coordinator.applicationDidLaunch()

        let transmissions = await transport.transmissions
        #expect(transmissions.count == 1)
        #expect(transmissions.first?.generation == 1)
    }

    @Test("a second launch trigger cancels the first transfer and resends the current version — liveness over a lost callback")
    func secondLaunchCancelsAndResends() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        try await coordinator.applicationDidLaunch()
        try await coordinator.applicationDidLaunch()

        let transmissions = await transport.transmissions
        let cancellations = await transport.cancellations
        #expect(transmissions.map(\.generation) == [1, 2])
        #expect(cancellations.map(\.generation) == [1])
    }

    // MARK: - isWatchAppInstalled edge trigger

    @Test("isWatchAppInstalled flipping false→true pushes exactly once; redundant true or a false push nothing")
    func watchInstalledEdgeTrigger() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        try await coordinator.watchAppInstalledDidChange(false) // already false, not installed
        #expect(await transport.transmissions.isEmpty)

        try await coordinator.watchAppInstalledDidChange(true) // the edge
        #expect(await transport.transmissions.count == 1)

        try await coordinator.watchAppInstalledDidChange(true) // redundant
        #expect(await transport.transmissions.count == 1)

        try await coordinator.watchAppInstalledDidChange(false) // uninstall
        #expect(await transport.transmissions.count == 1)

        try await coordinator.watchAppInstalledDidChange(true) // a genuine re-install
        #expect(await transport.transmissions.count == 2)
    }

    // MARK: - Catalog-edit debounce (§5: "debounced 5 s")

    @Test("a burst of catalog edits collapses into exactly one push, and nothing fires before the quiet period elapses")
    func catalogEditBurstCollapsesIntoOnePush() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: scheduler)

        await coordinator.catalogDidChange()
        await coordinator.catalogDidChange()
        await coordinator.catalogDidChange()

        await scheduler.waitUntilWaiting(count: 3)

        // No `drainPendingDebounces()` here: at 4.9 s none of the three
        // registered sleeps has reached its 5 s deadline, so `drain()`
        // (which awaits every spawned task's completion) would block
        // forever waiting on tasks that are correctly still suspended. The
        // absence of a transmission needs no synchronization to observe.
        await scheduler.advance(by: .seconds(4.9))
        #expect(await transport.transmissions.isEmpty, "must not fire before the quiet period elapses")

        await scheduler.advance(by: .seconds(0.1)) // total 5.0 s
        await coordinator.drainPendingDebounces()
        let transmissions = await transport.transmissions
        #expect(transmissions.count == 1, "three edits in one burst must reach the machine as exactly one .catalogChanged")
    }

    @Test("a new edit restarts the countdown: quiet-period-from-the-last-edit is what must elapse, not quiet-period-from-the-first")
    func newEditRestartsTheCountdown() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: scheduler)

        await coordinator.catalogDidChange() // t=0, deadline 5
        await scheduler.waitUntilWaiting(count: 1)
        await scheduler.advance(by: .seconds(3)) // t=3, before the first deadline

        await coordinator.catalogDidChange() // a second edit restarts the window: deadline now 3+5=8
        await scheduler.waitUntilWaiting(count: 2)

        // No `drain()` at t=5: the *second* edit's task (deadline 8) is
        // still correctly suspended, and `drain()` awaits every spawned
        // task unconditionally, so it would block on that one. The stale
        // first task resuming as a no-op needs no synchronization to
        // observe its absence of effect.
        await scheduler.advance(by: .seconds(2)) // t=5: the FIRST edit's original deadline, must NOT fire
        #expect(await transport.transmissions.isEmpty, "the first edit's timer must be superseded, not merely delayed")

        await scheduler.advance(by: .seconds(3)) // t=8: 5 s after the SECOND edit
        await coordinator.drainPendingDebounces()
        #expect(await transport.transmissions.count == 1)
    }

    @Test("a custom debounce window is honored")
    func customDebounceWindowIsHonored() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1))
        )

        await coordinator.catalogDidChange()
        await scheduler.waitUntilWaiting(count: 1)
        // No `drain()` before the deadline — see the burst test above.
        await scheduler.advance(by: .milliseconds(999))
        #expect(await transport.transmissions.isEmpty)

        await scheduler.advance(by: .milliseconds(1))
        await coordinator.drainPendingDebounces()
        #expect(await transport.transmissions.count == 1)
    }

    // MARK: - Digest-publish coalescing (binding contract item 6)

    @Test("a burst of history-changed signals coalesces into one digest publish carrying the latest acked set")
    func historyChangedBurstCoalescesIntoOnePublish() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let scheduler = ManualTriggerScheduler()
        let digestPublisher = FakeDigestPublisher()
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: FakeTransport(),
            digestPublisher: digestPublisher,
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: TestClock(),
            scheduler: scheduler
        )

        // Two real ingests, each of which produces its own `publishDigest`
        // command — the burst this test collapses.
        let sessionOne = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: sessionOne, needsNamingExercises: []))
        let sessionTwo = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: sessionTwo, needsNamingExercises: []))

        await scheduler.waitUntilWaiting(count: 2)
        await scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        let published = await digestPublisher.published
        #expect(published.count == 1, "two acks arriving within the quiet period must publish exactly once")
        #expect(Set(published.first?.ackedSessionIDs ?? []) == [sessionOne.id, sessionTwo.id], "the one publish must carry the latest, complete acked set — not the first ack's stale snapshot")
    }

    // MARK: - Daily push

    @Test("the first daily check always fires; a second check before the interval elapses does not; one after the interval does")
    func dailyPushFiresOnceEveryInterval() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let clock = TestClock()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: ManualTriggerScheduler(), clock: clock,
            configuration: .init(dailyPushInterval: 24 * 60 * 60)
        )

        try await coordinator.dailyPushIfDue()
        #expect(await transport.transmissions.count == 1)

        clock.advance(by: 23 * 60 * 60)
        try await coordinator.dailyPushIfDue()
        #expect(await transport.transmissions.count == 1, "not due yet")

        clock.advance(by: 2 * 60 * 60) // total 25 h since the first fire
        try await coordinator.dailyPushIfDue()
        #expect(await transport.transmissions.count == 2, "due now")
    }

    @Test("the daily push due-state survives a relaunch via the persisted runtime state")
    func dailyPushDueStateSurvivesRelaunch() async throws {
        let store = try makePhoneStore()
        let clock = TestClock()
        let statePersisting = InMemoryPhoneSyncStatePersisting()
        let transportOne = FakeTransport()
        let coordinatorOne = PhoneSyncCoordinator(
            store: store, transport: transportOne, digestPublisher: FakeDigestPublisher(),
            statePersisting: statePersisting, clock: clock, scheduler: ManualTriggerScheduler()
        )
        try await coordinatorOne.dailyPushIfDue()
        #expect(await transportOne.transmissions.count == 1)

        // "Relaunch": a fresh coordinator over the same persisted state and
        // the same (advanced-by-1h, still-not-due) clock.
        clock.advance(by: 60 * 60)
        let transportTwo = FakeTransport()
        let coordinatorTwo = PhoneSyncCoordinator(
            store: store, transport: transportTwo, digestPublisher: FakeDigestPublisher(),
            statePersisting: statePersisting, clock: clock, scheduler: ManualTriggerScheduler()
        )
        try await coordinatorTwo.dailyPushIfDue()
        #expect(await transportTwo.transmissions.isEmpty, "the fresh instance must not forget yesterday's push and fire again")
    }

    // MARK: - Snapshot transfer bookkeeping

    @Test("snapshotTransferFinished clears the outstanding slot only for the exact (version, generation) it names")
    func snapshotTransferFinishedClearsOnlyExactIdentity() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        try await coordinator.applicationDidLaunch() // version 0, generation 1
        #expect(coordinator.currentMachineState.outstandingSnapshot != nil)

        // A stale callback naming the wrong generation must not clear it.
        try await coordinator.snapshotTransferFinished(version: 0, generation: 999)
        #expect(coordinator.currentMachineState.outstandingSnapshot != nil)

        try await coordinator.snapshotTransferFinished(version: 0, generation: 1)
        #expect(coordinator.currentMachineState.outstandingSnapshot == nil)
    }

    @Test("a catalog change transmits the built snapshot payload from real store content")
    func catalogChangeTransmitsRealStoreContent() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        try store.createRoutine(routine)

        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: scheduler)

        await coordinator.catalogDidChange()
        await scheduler.waitUntilWaiting(count: 1)
        await scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        let transmissions = await transport.transmissions
        #expect(transmissions.count == 1)
        #expect(transmissions.first?.payload.exercises.map(\.id) == [bench.id])
        #expect(transmissions.first?.payload.routines.map(\.id) == [routine.id])
        #expect(transmissions.first?.payload.version == 1)
    }
}
