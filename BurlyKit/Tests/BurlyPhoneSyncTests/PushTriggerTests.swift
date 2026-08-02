// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — spec §5's push triggers: "snapshot on app launch, on any routine/
// catalog edit (debounced 5 s), when isWatchAppInstalled flips true, and
// daily. ... Digest is refreshed whenever history changes ... A newer
// snapshot cancels any outstanding snapshot transfer." Every timing
// assertion here runs under `ManualTriggerScheduler`/`TestClock` — no real
// sleeping, no wall-clock jitter, exact boundaries asserted directly.
//
// Also covers m4-04 review round 1 majors 3 (a trigger's "done" state is
// only set after a successful push), 4 (command batches never interleave
// across transport awaits), and 5 (digest publications read current state
// at fire time, not schedule time).
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

    @Test("major 3 — a failed install-flip push retains retry state: the next call, even a redundant true, retries it")
    func watchInstalledRetriesAfterAFailedPush() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        await transport.setFailNextTransmitCount(1)
        await #expect(throws: FakeTransport.TransmitFailure.self) {
            try await coordinator.watchAppInstalledDidChange(true)
        }
        #expect(await transport.transmissions.isEmpty, "the failed attempt must not have enqueued anything")

        // A redundant `true` — pre-fix, this would be a silent no-op
        // forever, since `isWatchAppInstalled` is already `true`.
        try await coordinator.watchAppInstalledDidChange(true)
        #expect(await transport.transmissions.count == 1, "the retry state must make a redundant true retry the failed push")
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

        // The redesigned coalescer (major 6) cancels superseded countdowns
        // rather than leaving them parked, so a burst settles to exactly
        // one live waiter — never three. `settle()` lets the cancellations
        // from the second/third calls actually finish removing the earlier
        // ones before we check.
        await scheduler.settle()
        #expect(scheduler.pendingCount == 1, "a burst must settle to exactly one pending countdown")

        // No `drainPendingDebounces()` here: at 4.9 s the one live
        // countdown has not reached its 5 s deadline, so `drain()` (which
        // awaits the coalescer's in-flight task unconditionally) would
        // block forever waiting on a task that is correctly still
        // suspended. The absence of a transmission needs no
        // synchronization to observe.
        scheduler.advance(by: .seconds(4.9))
        #expect(await transport.transmissions.isEmpty, "must not fire before the quiet period elapses")

        scheduler.advance(by: .seconds(0.1)) // total 5.0 s
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
        let firstWaiterID = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(3)) // t=3, before the first deadline

        await coordinator.catalogDidChange() // a second edit: cancels the first, restarts the window at 3+5=8
        // Wait for the SECOND registration specifically — a plain "wait
        // until >= 1 waiter" could return while the first, not-yet-
        // cancelled waiter is still the only one present.
        _ = await scheduler.waitForFreshWaiter(excluding: [firstWaiterID])
        #expect(scheduler.pendingCount == 1, "the superseded first countdown must be gone, not merely joined by a second")

        // No `drain()` at t=5: `drain()` awaits the coalescer's in-flight
        // task unconditionally, and the live (second) countdown's deadline
        // (8) has not been reached yet.
        scheduler.advance(by: .seconds(2)) // t=5: the FIRST edit's original deadline, must NOT fire
        #expect(await transport.transmissions.isEmpty, "the first edit's timer must be superseded, not merely delayed")

        scheduler.advance(by: .seconds(3)) // t=8: 5 s after the SECOND edit
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
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        // No `drain()` before the deadline — see the burst test above.
        scheduler.advance(by: .milliseconds(999))
        #expect(await transport.transmissions.isEmpty)

        scheduler.advance(by: .milliseconds(1))
        await coordinator.drainPendingDebounces()
        #expect(await transport.transmissions.count == 1)
    }


    @Test("major 3 — a catalog push failure is surfaced on lastCatalogPushFailure and retried automatically, without re-bumping the snapshot version")
    func catalogPushSurfacesAndRetriesOnFailure() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1), catalogPushRetryCount: 2)
        )

        await transport.setFailNextTransmitCount(1)
        await coordinator.catalogDidChange()
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1)) // fires, fails once
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.isEmpty, "the first attempt failed and must not have recorded a transmission")
        #expect(coordinator.lastCatalogPushFailure != nil, "the failure must be surfaced")
        #expect(coordinator.currentMachineState.latestSnapshotVersion == 1, "exactly one .catalogChanged reached the machine, despite two transport attempts")

        // The retry is scheduled internally (not via catalogDidChange()) —
        // advance past its own quiet period.
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.count == 1, "the retry must succeed and land the transmission")
        #expect(coordinator.lastCatalogPushFailure == nil, "a subsequent success clears the surfaced failure")
        #expect(coordinator.currentMachineState.latestSnapshotVersion == 1, "still exactly one version bump for the one edit")
    }

    @Test("round 2, finding 4 — a catalog-edit STATE PERSISTENCE failure is surfaced and retried, exactly like a transport failure")
    func catalogPersistenceFailureIsSurfacedAndRetried() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let persisting = FailableStatePersisting()
        let coordinator = PhoneSyncCoordinator(
            store: store, transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1), catalogPushRetryCount: 2)
        )

        persisting.setFailNextSaveCount(1)
        await coordinator.catalogDidChange()
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1)) // fires; persistRuntimeState() fails
        await coordinator.drainPendingDebounces()

        // Pre-fix: `deliver`'s generic `try?` swallowed this outright — no
        // surfaced failure, no retry, ever, for this edit; the transport
        // was never even reached because `deliverCatalogChanged` bailed
        // out before computing anything to execute.
        #expect(await transport.transmissions.isEmpty, "the transport must not have been reached yet — persistence failed first")
        #expect(coordinator.lastCatalogPushFailure != nil, "a persistence failure must be surfaced exactly like a transport failure")

        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1)) // the retry: persistence now succeeds
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.count == 1, "the retried persist-then-execute must land the transmission")
        #expect(coordinator.lastCatalogPushFailure == nil)
        #expect(coordinator.currentMachineState.latestSnapshotVersion == 1, "still exactly one version bump for the one edit, despite the persistence retry")
    }

    @Test("round 2, finding 5 — a stale catalog retry does not resurrect a transfer a newer, already-completed catalog batch already superseded")
    func staleCatalogRetryDoesNotResurrectASupersededTransfer() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1), catalogPushRetryCount: 1)
        )

        // Edit A: its one and only transport attempt fails, scheduling a
        // retry that will replay A's captured commands — [transmit(1,1)] —
        // exactly as built at THIS delivery, before B ever ran.
        await transport.setFailNextTransmitCount(1)
        await coordinator.catalogDidChange()
        let editWaiterID = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.isEmpty, "A's only attempt failed")
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 1)
        let retryWaiterID = await scheduler.waitForFreshWaiter(excluding: [editWaiterID])
        // Round 3, §6: capture the retry Task's handle NOW (it was
        // scheduled synchronously inside A's failed execute attempt, which
        // the drain above fully awaited) — awaiting it later is the
        // deterministic completion signal the old 50 ms settle could not
        // give.
        let staleRetryTask = try #require(coordinator.mostRecentCatalogRetryTaskForTesting)

        // Edit B arrives next. Its own debounce ties A's retry EXACTLY on
        // paper (both scheduled `catalogEditDebounce` after the same
        // instant) — the same ambiguity real OS timer scheduling has no
        // obligation to resolve one particular way. `resumeWaiter(id:)`
        // forces B's timer to fire on its own, modeling whichever real
        // ordering could actually occur, without this test depending on
        // which one the scheduler happens to process first.
        await coordinator.catalogDidChange()
        let bWaiterID = await scheduler.waitForFreshWaiter(excluding: [editWaiterID, retryWaiterID])

        scheduler.resumeWaiter(id: bWaiterID)
        await coordinator.drainPendingDebounces()

        // B fully succeeded: cancel(1) then transmit(2,2), and it is now
        // the outstanding transfer.
        #expect(await transport.cancellations.map(\.generation) == [1])
        #expect(await transport.transmissions.map(\.generation) == [2])
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 2)

        // NOW let A's stale retry fire. Pre-fix, this replays transmit(1,1)
        // unconditionally, resurrecting the generation B's own cancel(1)
        // just retired. Post-fix, the retry's captured epoch no longer
        // matches — B's delivery bumped `catalogBatchEpoch` — so the retry
        // backs off without touching the transport at all.
        scheduler.resumeWaiter(id: retryWaiterID)
        // Round 3, §6: await the retry Task itself — when this resumes,
        // the stale retry has DEFINITELY run to completion: it reached its
        // epoch check and either backed off (post-fix) or fully replayed
        // its stale transmit (pre-fix). The negative assertions below can
        // therefore never run "too early"; against pre-fix code this pin
        // fails deterministically, not by scheduling luck. (The awaiting
        // test suspends off the main actor, so the retry's own hop onto it
        // cannot deadlock.)
        await staleRetryTask.value

        #expect(await transport.transmissions.map(\.generation) == [2], "A's stale retry must NOT have resurrected generation 1")
        #expect(await transport.cancellations.map(\.generation) == [1], "no new cancel either — the stale retry must be a complete no-op")
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 2, "B's transfer remains outstanding, untouched by the stale retry")
    }

    @Test("round 4, §3 — a rejected catalog persist never leaves ceiling+1 in memory: a digest queued BEFORE the failed edit publishes the last VALID version, and nothing above the ceiling ever reaches the publisher")
    func rejectedOverflowPersistNeverLeaksCeilingPlusOneToTheDigestPublisher() async throws {
        let persisting = InMemoryPhoneSyncStatePersisting(PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: maximumPhoneSyncIdentity, lastTransferGeneration: 1)
        ))
        let transport = FakeTransport()
        let digestPublisher = FakeDigestPublisher()
        let scheduler = ManualTriggerScheduler()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: digestPublisher,
            statePersisting: persisting, clock: TestClock(), scheduler: scheduler,
            // Short catalog debounce, long digest debounce: the failing
            // catalog edit fires INSIDE the digest's quiet period. Zero
            // retries: an overflow is deterministic, and no untracked
            // retry task should exist in this pin.
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(5), catalogPushRetryCount: 0)
        )

        // Queue a digest while the version sits at the (valid) ceiling —
        // it fires only at t=5, reading state at FIRE time (major 5).
        try await coordinator.historyDidChange()
        await scheduler.waitUntilWaiting(count: 1)

        // A catalog edit whose delivery is REJECTED at persist time (the
        // version increment would pass the ceiling). Pre-fix,
        // machine.handle had already committed ceiling+1 to the shared
        // in-memory state before persistence could refuse it — and the
        // already-queued digest then read and published that value
        // (BurlyDigestPayloadDTO only requires a nonnegative version).
        await coordinator.catalogDidChange()
        await scheduler.waitUntilWaiting(count: 2)
        scheduler.advance(by: .seconds(1)) // catalog fires; persist rejects
        // Deterministic completion signal: the surfaced failure is set
        // synchronously at the end of the failed delivery — a positive
        // condition polled to arrival, not a wall-clock "prove absence"
        // wait (the negative assertions below run strictly after it).
        while coordinator.lastCatalogPushFailure == nil {
            await Task.yield()
        }

        #expect(
            coordinator.currentMachineState.latestSnapshotVersion == maximumPhoneSyncIdentity,
            "ceiling+1 must never exist in memory — a rejected persist means the event never happened"
        )

        // NOW the queued digest fires, inside the failed edit's aftermath.
        scheduler.advance(by: .seconds(4)) // t=5: the digest's own deadline
        await coordinator.drainPendingDebounces()

        let published = await digestPublisher.published
        #expect(published.count == 1, "the digest itself still publishes — history genuinely changed")
        #expect(
            published.first?.snapshotVersion == maximumPhoneSyncIdentity,
            "it must carry the last validly-persisted version, not the rejected increment"
        )
        #expect(
            published.allSatisfy { $0.snapshotVersion <= maximumPhoneSyncIdentity },
            "nothing above the ceiling may EVER reach the digest publisher"
        )
        #expect(await transport.transmissions.isEmpty, "and the snapshot transport stays untouched, as in round 3")
    }

    @Test("round 4 audit — a catalog transport retry backs off when a NON-catalog push superseded its transfer: generation freshness, not just the catalog epoch")
    func staleCatalogRetryBacksOffAfterANonCatalogSupersession() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1), catalogPushRetryCount: 1)
        )

        // Catalog edit A: state commits (version 1, generation 1), but the
        // transport attempt fails — a retry of A's committed commands is
        // scheduled.
        await transport.setFailNextTransmitCount(1)
        await coordinator.catalogDidChange()
        let editWaiterID = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await coordinator.drainPendingDebounces()
        #expect(await transport.transmissions.isEmpty, "A's only transport attempt failed")
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 1)
        let retryWaiterID = await scheduler.waitForFreshWaiter(excluding: [editWaiterID])
        let staleRetryTask = try #require(coordinator.mostRecentCatalogRetryTaskForTesting)

        // A NON-catalog push supersedes A's transfer: launch cancels
        // (1, 1) and transmits (1, 2). Crucially, `catalogBatchEpoch` does
        // NOT change here — pre-fix, that epoch was the retry's ONLY
        // freshness signal, so the retry replayed transmit(1, 1) and
        // resurrected the transfer this launch push just retired.
        try await coordinator.applicationDidLaunch()
        #expect(await transport.cancellations.map(\.generation) == [1])
        #expect(await transport.transmissions.map(\.generation) == [2])
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 2)

        // Release A's retry and await its completion (deterministic, round
        // 3 §6 discipline) — post-fix it must be a complete no-op.
        scheduler.resumeWaiter(id: retryWaiterID)
        await staleRetryTask.value

        #expect(await transport.transmissions.map(\.generation) == [2], "the retry must NOT resurrect generation 1 after the launch push superseded it")
        #expect(await transport.cancellations.map(\.generation) == [1], "and must issue no new cancel either")
        #expect(coordinator.currentMachineState.outstandingSnapshot?.generation == 2, "the launch push's transfer remains the live one")
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

        await scheduler.settle()
        #expect(scheduler.pendingCount == 1, "the burst must settle to exactly one pending countdown")
        scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        let published = await digestPublisher.published
        #expect(published.count == 1, "two acks arriving within the quiet period must publish exactly once")
        #expect(Set(published.first?.ackedSessionIDs ?? []) == [sessionOne.id, sessionTwo.id], "the one publish must carry the latest, complete acked set — not the first ack's stale snapshot")
    }

    @Test("major 5 — a digest publish reads the snapshot version and acked set current AT FIRE TIME, not captured when the burst started")
    func digestPublishReadsCurrentStateAtFireTimeNotScheduleTime() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        try store.createRoutine(routine)
        let scheduler = ManualTriggerScheduler()
        let digestPublisher = FakeDigestPublisher()
        // A short catalog debounce, a longer digest debounce, so the
        // catalog edit's version bump lands WHILE the digest publish is
        // still in its own quiet period.
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: FakeTransport(),
            digestPublisher: digestPublisher,
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: TestClock(),
            scheduler: scheduler,
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(5))
        )

        // A session ingest schedules a digest publish while
        // `latestSnapshotVersion == 0`.
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: session, needsNamingExercises: []))
        #expect(coordinator.currentMachineState.latestSnapshotVersion == 0)

        // A catalog edit, scheduled at the same moment, whose OWN (shorter)
        // debounce elapses first and bumps the version to 1 before the
        // digest's quiet period is over.
        await coordinator.catalogDidChange()

        await scheduler.waitUntilWaiting(count: 2) // both countdowns registered — nothing superseded yet, safe to count
        scheduler.advance(by: .seconds(1)) // catalog fires -> version bumps to 1
        // NOT `drainPendingDebounces()` here: it drains BOTH coalescers, and
        // the digest one's countdown (deadline 5) has not been reached yet
        // — draining it would hang waiting for a task that cannot resolve
        // until the next `advance` below. `settle()` just lets the
        // catalog's own resumed task run (its version bump is synchronous,
        // reached well before its own transport await).
        await scheduler.settle()
        #expect(coordinator.currentMachineState.latestSnapshotVersion == 1)

        scheduler.advance(by: .seconds(4)) // total 5s since the session ingest -> digest fires
        await coordinator.drainPendingDebounces()

        let published = await digestPublisher.published
        let digest = try #require(published.first)
        #expect(published.count == 1)
        #expect(digest.snapshotVersion == 1, "must reflect the version at FIRE time, not the 0 that was current when the burst started")
        #expect(digest.ackedSessionIDs == [session.id])
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

    @Test("major 3 — a failed daily push does not mark the day consumed: the next check still retries rather than waiting a full interval")
    func dailyPushDoesNotMarkDoneOnFailure() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let clock = TestClock()
        let coordinator = makeCoordinator(
            store: store, transport: transport, scheduler: ManualTriggerScheduler(), clock: clock,
            configuration: .init(dailyPushInterval: 24 * 60 * 60)
        )

        await transport.setFailNextTransmitCount(1)
        await #expect(throws: FakeTransport.TransmitFailure.self) {
            try await coordinator.dailyPushIfDue()
        }
        #expect(await transport.transmissions.isEmpty)

        // Only a few minutes later — pre-fix, `lastDailyPushAt` would
        // already have been set by the failed attempt, suppressing this
        // for a full 24 h.
        clock.advance(by: 5 * 60)
        try await coordinator.dailyPushIfDue()
        #expect(await transport.transmissions.count == 1, "the failure must not have consumed the day's push")
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
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        let transmissions = await transport.transmissions
        #expect(transmissions.count == 1)
        #expect(transmissions.first?.payload.exercises.map(\.id) == [bench.id])
        #expect(transmissions.first?.payload.routines.map(\.id) == [routine.id])
        #expect(transmissions.first?.payload.version == 1)
    }

    // MARK: - Major 4: command batches never interleave across transport awaits

    @Test("major 4 — a second push's command batch never starts its own transport calls until the first push's whole batch has finished")
    func commandBatchesNeverInterleaveAcrossTransportAwaits() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(store: store, transport: transport, scheduler: ManualTriggerScheduler())

        // Establish an outstanding transfer at generation 1.
        try await coordinator.applicationDidLaunch()
        #expect(await transport.transmissions.map(\.generation) == [1])

        // Arm the gate: the NEXT cancelSnapshotTransfer call suspends until
        // released, letting this test hold "Push A is mid-batch" open.
        await transport.armCancelGate()

        // Push A: a second launch trigger -> [cancel(1), transmit(2)].
        // Spawned concurrently since it will suspend inside the gated
        // cancel call.
        let pushA = Task { try await coordinator.applicationDidLaunch() }

        // Deterministically wait for Push A to have actually reached the
        // gated call (not a guessed delay).
        while await transport.hasCancelGateWaiter() == false {
            await Task.yield()
        }

        // Push B: a third launch trigger, started while Push A is
        // suspended mid-batch. Pre-fix, `@MainActor` isolation alone does
        // not stop this from interleaving its OWN cancel/transmit calls
        // with Push A's, since Push A is suspended at an `await`. Post-fix,
        // this must block on the execution lock and touch the transport
        // not at all until Push A's whole batch — cancel AND transmit —
        // has finished.
        let pushB = Task { try await coordinator.applicationDidLaunch() }

        // Deterministically wait for Push B to have actually reached (and
        // blocked on) the execution lock.
        while coordinator.executionWaiterCountForTesting == 0 {
            await Task.yield()
        }
        #expect(await transport.cancellations.isEmpty, "Push B must not have touched the transport yet")
        #expect(await transport.transmissions.map(\.generation) == [1], "Push B's transmit must not have started either")

        await transport.releaseCancelGate()
        try await pushA.value
        try await pushB.value

        // Strict ordering: Push A's cancel/transmit pair lands before Push
        // B's — never interleaved.
        let cancellations = await transport.cancellations.map(\.generation)
        let transmissions = await transport.transmissions.map(\.generation)
        #expect(cancellations == [1, 2], "Push A's cancel(1) then Push B's cancel(2), never reordered")
        #expect(transmissions == [1, 2, 3], "Push A's transmit(2) fully lands before Push B's transmit(3) starts")
    }
}
