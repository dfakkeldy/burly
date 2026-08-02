// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — `PhoneSyncCoordinator.sessionReceived(_:)`, the binding contract
// (SyncMachineBinding.swift) executed against a real `SwiftDataStore`. Each
// test below is named for the contract item(s) it pins.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

// `@MainActor`: `PhoneSyncCoordinator` is main-actor-isolated (see that
// type's doc — the store's own single-isolation-domain requirement), and
// these tests touch the same `SwiftDataStore` both through the coordinator
// and directly (to assert on it), which only type-checks under Swift 6's
// strict concurrency when both uses share one isolation domain.
@MainActor
@Suite("m4-04 — PhoneSyncCoordinator: session ingest binding contract")
struct PhoneSessionIngestTests {

    private func makeCoordinator(
        store: any BurlyStore,
        clock: any WallClock = TestClock(),
        transport: FakeTransport = FakeTransport(),
        digestPublisher: FakeDigestPublisher = FakeDigestPublisher(),
        statePersisting: any PhoneSyncStatePersisting = InMemoryPhoneSyncStatePersisting()
    ) -> PhoneSyncCoordinator {
        PhoneSyncCoordinator(
            store: store,
            transport: transport,
            digestPublisher: digestPublisher,
            statePersisting: statePersisting,
            clock: clock,
            scheduler: ManualTriggerScheduler()
        )
    }

    // MARK: - The absent-session create path

    @Test("an absent session creates it, upserts its needsNaming placeholder exercises, acks, and (after the debounce) publishes a digest")
    func absentSessionCreatesAndAcksAndPublishes() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])

        let placeholder = Fixture.exercise(name: "Custom", origin: .custom, needsNaming: true)
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

        var session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        session.items.append(SessionItemData(
            exerciseID: placeholder.id, order: 1,
            sets: [SetRecordData(order: 0, weight: Weight(kg: 20), reps: 8, completedAt: Fixture.epoch)]
        ))
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [placeholder])

        try await coordinator.sessionReceived(payload)

        // The placeholder landed in the catalog, unnamed, per §6.
        let storedPlaceholder = try #require(try store.exercise(id: placeholder.id))
        #expect(storedPlaceholder.needsNaming)

        // The session itself is durably stored.
        #expect(try store.session(id: session.id) == session)

        // The ack is recorded — the machine's ackAge dictionary carries it.
        let stateAfterIngest = coordinator.currentMachineState
        #expect(stateAfterIngest.ackAge.keys.contains(session.id))
        #expect(stateAfterIngest.pendingStoreConfirmations.isEmpty)

        // The digest publish is debounced (item 6) — nothing has gone out
        // yet, then it lands once the quiet period elapses.
        var published = await digestPublisher.published
        #expect(published.isEmpty)

        await scheduler.waitUntilWaiting(count: 1)
        scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        published = await digestPublisher.published
        #expect(published.count == 1)
        #expect(published.first?.ackedSessionIDs == [session.id])
    }

    @Test("a needsNaming exercise already known to the phone is never overwritten by a redelivery")
    func existingPlaceholderExerciseIsNotOverwritten() async throws {
        let store = try makePhoneStore()
        let placeholder = Fixture.exercise(name: "Renamed by Dan", origin: .custom, needsNaming: false)
        try store.createExercise(placeholder)

        let routine = Fixture.routine(over: [placeholder])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        // The DTO still embeds the placeholder as the watch last knew it —
        // unnamed — because the watch has not yet received the phone's
        // rename via a snapshot.
        let stalePlaceholderCopy = Fixture.exercise(
            id: placeholder.id, name: "Custom", origin: .custom, needsNaming: true
        )
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [stalePlaceholderCopy])

        let coordinator = makeCoordinator(store: store)
        try await coordinator.sessionReceived(payload)

        let stored = try #require(try store.exercise(id: placeholder.id))
        #expect(stored.name == "Renamed by Dan")
        #expect(stored.needsNaming == false)
    }

    // MARK: - Dedupe / re-ack (§5 idempotency)

    @Test("a redelivery at the same revision does not rewrite the session, but still re-confirms and re-publishes")
    func redeliveryAtSameRevisionReconfirmsWithoutRewriting() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [])

        let coordinator = makeCoordinator(store: store)
        try await coordinator.sessionReceived(payload)
        let afterFirst = try store.session(id: session.id)

        // A ghost redelivery of the identical payload — same revision.
        try await coordinator.sessionReceived(payload)

        #expect(try store.session(id: session.id) == afterFirst)
        let state = coordinator.currentMachineState
        #expect(state.ackAge.keys.contains(session.id))
        #expect(state.pendingStoreConfirmations.isEmpty)
    }

    @Test("a lower-revision redelivery after a phone edit is dropped, never overwriting the phone's edit, and still re-acks")
    func lowerRevisionRedeliveryAfterAPhoneEditIsDropped() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [])

        let coordinator = makeCoordinator(store: store)
        try await coordinator.sessionReceived(payload)

        // The phone edits the session (§6) — a call the sync runtime never
        // makes on its own, standing in for the app's editor.
        var edited = session
        edited.notes = "edited on phone"
        _ = try store.applyPhoneEdit(edited)
        let afterEdit = try store.session(id: session.id)
        #expect(afterEdit?.revision == 2)

        // The watch, unaware of the edit, redelivers its original revision-1
        // payload (a lost-ack retry).
        try await coordinator.sessionReceived(payload)

        #expect(try store.session(id: session.id) == afterEdit, "the phone's edit must survive a stale watch redelivery")
        let state = coordinator.currentMachineState
        #expect(state.ackAge.keys.contains(session.id), "the watch is still owed an ack so its retry stops")
    }

    // MARK: - Item 3: a failed transaction sends nothing

    @Test("item 3 / major 1 — a session naming an exercise the phone has never heard of fails closed atomically: no session row, no placeholder residue, no ack, no publish")
    func missingExerciseReferenceFailsClosedWithNoAckOrPublish() async throws {
        let store = try makePhoneStore()
        let placeholder = Fixture.exercise(name: "Custom", origin: .custom, needsNaming: true)
        let unrelatedGhostExerciseID = UUID()

        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(exerciseID: placeholder.id, order: 0),
                SessionItemData(exerciseID: unrelatedGhostExerciseID, order: 1)
            ]
        )
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [placeholder])

        let digestPublisher = FakeDigestPublisher()
        let scheduler = ManualTriggerScheduler()
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: FakeTransport(),
            digestPublisher: digestPublisher,
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: TestClock(),
            scheduler: scheduler
        )

        try await coordinator.sessionReceived(payload)

        // m4-04 review round 1, major 1: the placeholder upsert and the
        // session apply are now ONE transaction
        // (`applyReplicatedSession(_:upsertingPlaceholderExercises:)`), so
        // a rejection of the session rolls the placeholder back too — it
        // must not survive as committed residue with no session, no ack,
        // and no way for a retry to know it was ever created for this
        // delivery (the failure mode the previous, two-save version of
        // this test explicitly blessed).
        #expect(try store.exercise(id: placeholder.id) == nil, "major 1: the placeholder must not survive a rejected delivery — it shares the session's transaction now")
        // The session itself never landed — preflight rejected it before
        // any row was touched, and `commit()`'s rollback-on-throw backstops
        // the same guarantee for a failure that reached a live save.
        #expect(try store.session(id: session.id) == nil)

        let state = coordinator.currentMachineState
        #expect(state.ackAge.keys.contains(session.id) == false, "no ack may exist for a session the store never durably held")
        #expect(state.pendingStoreConfirmations.keys.contains(session.id), "the routing is still pending — the watch's retry is owed a real answer")

        await coordinator.drainPendingDebounces()
        let published = await digestPublisher.published
        #expect(published.isEmpty, "item 3: a failed transaction publishes nothing")
    }

    // MARK: - Item 4: failed verification re-drives, never confirms stale

    @Test("item 4 — a confirmSessionStored verification that finds the row gone re-drives through sessionReceived instead of confirming from the stale decision")
    func confirmVerificationFindingTheRowGoneRedrivesInstead() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [])

        let coordinator = makeCoordinator(store: store)
        // Genuinely create and ack it first.
        try await coordinator.sessionReceived(payload)
        #expect(try store.session(id: session.id) != nil)

        // Simulate the race the binding contract's item 4 exists for: the
        // advisory lookup behind some *other* routing decided "already
        // covered" — but by the time the store is actually verified, the
        // row is gone (a concurrent §1 `deleteSession`, per the contract's
        // own example). Injected directly at the command-execution seam
        // (see `PhoneSyncCoordinator.execute`'s doc) rather than through a
        // real race, which cannot be made deterministic in a unit test.
        try store.deleteSession(id: session.id)
        #expect(try store.session(id: session.id) == nil)

        try await coordinator.execute(
            [.confirmSessionStored(id: session.id, revision: session.revision)],
            originalPayload: payload
        )

        // The re-drive recreated the session from the original payload —
        // proof this went through `.sessionReceived` again (storedRevision
        // now nil) rather than confirming from the stale decision, which
        // would have left the row permanently gone despite an ack existing
        // for it.
        #expect(try store.session(id: session.id) == session)
        let state = coordinator.currentMachineState
        #expect(state.ackAge.keys.contains(session.id), "the re-drive earned a fresh, honest ack")
    }

    @Test("item 4 — verification with no original payload to re-route with does nothing rather than confirming")
    func confirmVerificationWithNoOriginalPayloadDoesNothing() async throws {
        let store = try makePhoneStore()
        let coordinator = makeCoordinator(store: store)
        let ghostID = UUID()

        // No payload in hand at all — an unreachable-in-practice shape (see
        // the coordinator's doc), but the safe behavior is "do nothing",
        // never synthesize a confirmation.
        try await coordinator.execute(
            [.confirmSessionStored(id: ghostID, revision: 1)],
            originalPayload: nil
        )

        let state = coordinator.currentMachineState
        #expect(state.ackAge.isEmpty)
    }

    // MARK: - Item 5: state persists with the ack, before the publish

    @Test("item 5 — the persisted machine state already carries the ack before the digest is published")
    func stateIsPersistedBeforeDigestPublish() async throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let payload = BurlySessionPayloadDTO(session: session, needsNamingExercises: [])

        let spy = OrderRecordingStatePersisting()
        let digestPublisher = OrderRecordingDigestPublisher(log: spy.log)
        let scheduler = ManualTriggerScheduler()
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: FakeTransport(),
            digestPublisher: digestPublisher,
            statePersisting: spy,
            clock: TestClock(),
            scheduler: scheduler
        )

        try await coordinator.sessionReceived(payload)
        await scheduler.waitUntilWaiting(count: 1)
        scheduler.advance(by: .seconds(5))
        await coordinator.drainPendingDebounces()

        let events = spy.log.snapshot
        let firstPersistWithAck = events.firstIndex { event in
            if case let .persisted(state) = event { return state.machineState.ackAge.keys.contains(session.id) }
            return false
        }
        let publishIndex = events.firstIndex { if case .published = $0 { return true }; return false }

        let persistIndex = try #require(firstPersistWithAck)
        let publish = try #require(publishIndex)
        #expect(persistIndex < publish, "the ack-bearing state must be durable before the publish it produced runs")
    }
}

// MARK: - Ordering spy
//
// A plain lock-protected class, not an actor: `PhoneSyncStatePersisting
// .save` is synchronous (by protocol design — see that file's doc), so
// recording through an actor would need a fire-and-forget `Task`, which
// reintroduces exactly the kind of unordered async gap this spy exists to
// rule out. A lock keeps "recorded before this call returns" true for both
// conformers below, which is what makes the resulting order trustworthy.
final class OrderLog: @unchecked Sendable {
    enum Event {
        case persisted(PhoneSyncRuntimeState)
        case published(BurlyDigestPayloadDTO)
    }
    private var events: [Event] = []
    private let lock = NSLock()

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var snapshot: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class OrderRecordingStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    let log = OrderLog()
    private var stored: PhoneSyncRuntimeState?

    func load() throws -> PhoneSyncLoadResult? {
        stored.map { PhoneSyncLoadResult(runtimeState: $0, recoveredFromCorruption: false) }
    }

    func save(_ state: PhoneSyncRuntimeState) throws {
        stored = state
        log.record(.persisted(state))
    }

    func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {
        try save(state)
    }
}

struct OrderRecordingDigestPublisher: PhoneDigestPublishing {
    let log: OrderLog
    func publishDigest(_ payload: BurlyDigestPayloadDTO) async {
        log.record(.published(payload))
    }
}
