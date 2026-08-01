// SPDX-License-Identifier: GPL-3.0-or-later
// m1-06 review, B1 — the store-owned active-session unit of work.
//
// The blocker these tests close: between §2's Start and Finish, the session
// engine changes facts that §1 *persists* — a swap rewrites an item's
// `exerciseID` or splits the item, add/reorder rewrites the item graph,
// Finish rewrites `state` and `endedAt` — while the plan/rest-timer
// scaffolding lives outside §1 entirely. Before this round the store could
// only create a session and append sets, so the straightforward M2
// integration would persist the routine copy once and then diverge from it,
// and any attempt to patch around that in the UI would write the set row
// and the journal in separate saves with a crash window between them.
//
// So these tests are written the way M2 will actually call the store: drive
// `SessionBuilder`/`SessionMutator` exactly as the watch does, hand the
// resulting `ActiveSession` to `saveActiveSession`, and then ask a *cold*
// container what actually landed. The engine is not stubbed out; if the
// store cannot durably represent what the engine produces, these fail.
//
// The revision rule is checked in its own section at the bottom: watch
// activity never moves `revision`, `applyPhoneEdit` always moves it by one.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m1-06 B1 — active-session transaction")
struct ActiveSessionTransactionTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    /// A watch store seeded with two exercises and the routine over them,
    /// plus the `ActiveSession` §2 Start would produce.
    private func startedSession(
        in store: SwiftDataStore,
        clock: any WallClock = TestClock()
    ) throws -> (active: ActiveSession, bench: ExerciseData, row: ExerciseData) {
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)
        return (SessionBuilder.session(from: routine, clock: clock), bench, row)
    }

    // MARK: - One transaction, whole record

    @Test("Start persists the session graph and the §2/§3 scaffolding together; a cold container returns the same ActiveSession")
    func startPersistsGraphAndScaffoldingInOneTransaction() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let written: ActiveSession
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: TestClock())
            var (active, _, _) = try startedSession(in: store)
            // A rest timer running at the moment of the write — §3 requires
            // it to be "part of the active session record".
            active.restTimer = RestTimerState(startedAt: Fixture.epoch, duration: 90)
            try store.saveActiveSession(active)
            written = active
        }

        let reopened = try SwiftDataStore(kind: .watch, at: .file(url))
        let resumed = try #require(try reopened.resumableActiveSession())

        #expect(resumed.session == written.session)
        #expect(resumed.plans == written.plans)
        #expect(resumed.restTimer == written.restTimer)
        #expect(resumed.isWellFormed)
        // The plan floor came from the routine's `defaultSetCount`, not
        // from a default the store invented.
        #expect(resumed.plans.values.map(\.plannedSetCount) == [3, 3])
        // …and the per-item rest override rode along with it.
        #expect(resumed.plan(resumed.items[0].id)?.restOverride == 120)
    }

    @Test("a swap before anything is logged rewrites the STORED exerciseID — the exact divergence B1 named")
    func swapBeforeLoggingRewritesTheStoredExerciseReference() throws {
        let store = try makeStore(.watch)
        var (active, bench, row) = try startedSession(in: store)
        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        try store.createExercise(curl)
        try store.saveActiveSession(active)

        let benchItemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
        let workedItemID = try SessionMutator.swapExercise(
            itemID: benchItemID,
            toExerciseID: curl.id,
            in: &active
        )
        try store.saveActiveSession(active)

        // In place: same item, new exercise. Before this round the stored
        // row kept pointing at bench forever.
        #expect(workedItemID == benchItemID)
        let stored = try #require(try store.session(id: active.id))
        #expect(stored.items.map(\.exerciseID) == [curl.id, row.id])
        #expect(stored.items.map(\.order) == [0, 1])
    }

    @Test("a swap after sets are logged persists BOTH halves of the split: the frozen item keeps its sets, the replacement lands after it")
    func swapAfterLoggingSplitsAndPersistsBothHalves() throws {
        let store = try makeStore(.watch)
        let clock = TestClock()
        var (active, bench, row) = try startedSession(in: store, clock: clock)
        let machine = Fixture.exercise(name: "Machine Press")
        try store.createExercise(machine)
        try store.saveActiveSession(active)

        let benchItemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
        try SessionMutator.logSet(
            itemID: benchItemID, weight: Weight(kg: 80), reps: 5, in: &active, clock: clock
        )
        clock.advance(by: 120)
        let newItemID = try SessionMutator.swapExercise(
            itemID: benchItemID,
            toExerciseID: machine.id,
            in: &active
        )
        try store.saveActiveSession(active)

        let stored = try #require(try store.session(id: active.id))
        #expect(stored.items.map(\.exerciseID) == [bench.id, machine.id, row.id])
        #expect(stored.items.map(\.order) == [0, 1, 2])
        // The performed half is history and keeps its set; the replacement
        // starts empty. Re-filing the logged set under the machine is
        // exactly what the engine refuses to do, and the store must not
        // undo that refusal on the way to disk.
        #expect(stored.items[0].sets.count == 1)
        #expect(stored.items[0].sets[0].weightKg == 80)
        #expect(stored.items[1].sets.isEmpty)
        // The scaffolding split with it: frozen item shrunk to what it
        // holds, replacement inherits the outstanding slots.
        let resumed = try #require(try store.activeSession(id: active.id))
        #expect(resumed.plan(benchItemID)?.plannedSetCount == 1)
        #expect(resumed.plan(newItemID)?.plannedSetCount == 2)
        #expect(resumed.plan(newItemID)?.restOverride == 120)
    }

    @Test("add exercise, skip, and reorder all reach the stored item graph")
    func addSkipAndReorderPersistTheItemGraph() throws {
        let store = try makeStore(.watch)
        var (active, bench, row) = try startedSession(in: store)
        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        try store.createExercise(curl)
        try store.saveActiveSession(active)

        let curlItemID = try SessionMutator.addExercise(
            exerciseID: curl.id, plannedSetCount: 4, in: &active
        )
        let rowItemID = try #require(active.items.first { $0.exerciseID == row.id }?.id)
        try SessionMutator.skipExercise(itemID: rowItemID, in: &active)
        try SessionMutator.moveItemUp(itemID: curlItemID, in: &active)
        try store.saveActiveSession(active)

        let stored = try #require(try store.session(id: active.id))
        #expect(stored.items.map(\.exerciseID) == [bench.id, curl.id, row.id])
        #expect(stored.items.map(\.order) == [0, 1, 2])

        let resumed = try #require(try store.activeSession(id: active.id))
        #expect(resumed.plan(curlItemID)?.plannedSetCount == 4)
        #expect(resumed.plan(rowItemID)?.isSkipped == true)
        #expect(resumed.unskippedItems.map(\.exerciseID) == [bench.id, curl.id])
    }

    @Test("the newly logged set and the plan that grew to match it become durable in the same save")
    func loggedSetAndScaffoldingLandTogether() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let clock = TestClock()
        var sessionID = UUID()
        var itemID = UUID()
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: clock)
            var (active, bench, _) = try startedSession(in: store, clock: clock)
            sessionID = active.id
            itemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
            try store.saveActiveSession(active)

            // Four sets against a 3-slot plan: the fourth is data, so the
            // plan grows (I4). Every one of these is one store call.
            for index in 0..<4 {
                clock.advance(by: 180)
                try SessionMutator.logSet(
                    itemID: itemID,
                    weight: Weight(kg: 60 + Double(index) * 2.5),
                    reps: 8 - index,
                    in: &active,
                    clock: clock
                )
                try store.saveActiveSession(active)
            }
        }

        let reopened = try SwiftDataStore(kind: .watch, at: .file(url))
        let resumed = try #require(try reopened.resumableActiveSession())
        #expect(resumed.id == sessionID)
        let item = try #require(resumed.item(itemID))
        #expect(item.sets.map(\.order) == [0, 1, 2, 3])
        #expect(item.sets.map(\.reps) == [8, 7, 6, 5])
        #expect(item.sets.map(\.weightKg) == [60, 62.5, 65, 67.5])
        // The plan grew with the fourth set rather than staying at the
        // routine's 3 — and it survived the cold open alongside the sets.
        #expect(resumed.plan(itemID)?.plannedSetCount == 4)
        #expect(resumed.isWellFormed)
    }

    // MARK: - Finish

    @Test("Finish writes state and endedAt and retires the journal in one save; nothing is left to resume")
    func finishTransitionsAndRetiresTheJournal() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let clock = TestClock()
        var sessionID = UUID()
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: clock)
            var (active, bench, _) = try startedSession(in: store, clock: clock)
            sessionID = active.id
            let itemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
            try store.saveActiveSession(active)
            try SessionMutator.logSet(
                itemID: itemID, weight: Weight(kg: 100), reps: 5, in: &active, clock: clock
            )
            active.restTimer = RestTimerState(startedAt: clock.now, duration: 90)
            try store.saveActiveSession(active)
            #expect(try store.resumableActiveSession() != nil)

            clock.advance(by: 3_600)
            try SessionMutator.finish(&active, clock: clock)
            try store.saveActiveSession(active)
        }

        let container = try BurlyContainer.make(.watch, at: .file(url))
        let reopened = SwiftDataStore(container: container)

        let stored = try #require(try reopened.session(id: sessionID))
        #expect(stored.state == .logged)
        #expect(stored.endedAt == Fixture.epoch.addingTimeInterval(3_600))
        #expect(stored.items.flatMap(\.sets).count == 1)
        // Finished means not in flight: the journal row is gone, Resume has
        // nothing to offer, and the session is queued for sync instead.
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 0)
        #expect(try reopened.resumableActiveSession() == nil)
        #expect(try reopened.activeSession(id: sessionID) == nil)
        #expect(try reopened.loggedSessionsAwaitingAck().map(\.id) == [sessionID])
    }

    // MARK: - Revision discipline

    @Test("no watch-authored mutation — not one of them, not Finish — moves revision off 1")
    func watchActivityNeverBumpsRevision() throws {
        let store = try makeStore(.watch)
        let clock = TestClock()
        var (active, bench, row) = try startedSession(in: store, clock: clock)
        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        try store.createExercise(curl)
        try store.saveActiveSession(active)

        let benchItemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
        let rowItemID = try #require(active.items.first { $0.exerciseID == row.id }?.id)

        try SessionMutator.addSet(toItem: benchItemID, in: &active)
        try store.saveActiveSession(active)
        try SessionMutator.logSet(
            itemID: benchItemID, weight: Weight(kg: 90), reps: 5, in: &active, clock: clock
        )
        try store.saveActiveSession(active)
        _ = try SessionMutator.swapExercise(itemID: rowItemID, toExerciseID: curl.id, in: &active)
        try store.saveActiveSession(active)
        _ = try SessionMutator.addExercise(exerciseID: curl.id, in: &active)
        try store.saveActiveSession(active)
        try SessionMutator.moveItemUp(itemID: rowItemID, in: &active)
        try store.saveActiveSession(active)
        try SessionMutator.finish(&active, clock: clock)
        try store.saveActiveSession(active)

        #expect(try store.session(id: active.id)?.revision == 1)
    }

    @Test("saveActiveSession ignores the revision a DTO claims on an already-stored session")
    func saveActiveSessionDoesNotTakeTheDTOsRevision() throws {
        let store = try makeStore(.watch)
        var (active, _, _) = try startedSession(in: store)
        try store.saveActiveSession(active)

        // A round-tripped or hand-built DTO claiming a later revision must
        // not be able to smuggle one in through the watch path: §5's
        // "incoming revision ≤ stored revision → drop" rule depends on a
        // bump meaning "a human edited this on the phone."
        active.session.revision = 42
        try store.saveActiveSession(active)

        #expect(try store.session(id: active.id)?.revision == 1)
    }

    @Test("applyPhoneEdit is the one path that increments revision — by exactly one per call, and never from the DTO")
    func phoneEditIsTheOnlyRevisionBump() throws {
        let store = try makeStore()
        var (active, bench, row) = try startedSession(in: store)
        let clock = TestClock()
        let benchItemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
        try SessionMutator.logSet(
            itemID: benchItemID, weight: Weight(kg: 100), reps: 5, in: &active, clock: clock
        )
        try SessionMutator.finish(&active, clock: clock)
        try store.saveActiveSession(active)
        #expect(try store.session(id: active.id)?.revision == 1)

        // §6: the phone corrects a rep count after the fact.
        var edited = try #require(try store.session(id: active.id))
        edited.items[0].sets[0].reps = 6
        // A forged revision in the payload changes nothing about the
        // arithmetic — the store increments what it has stored.
        edited.revision = 99
        #expect(try store.applyPhoneEdit(edited) == 2)
        #expect(try store.applyPhoneEdit(edited) == 3)

        let stored = try #require(try store.session(id: active.id))
        #expect(stored.revision == 3)
        #expect(stored.items[0].sets[0].reps == 6)
        #expect(stored.items.map(\.exerciseID) == [bench.id, row.id])
    }

    @Test("applyPhoneEdit removes items and sets the payload dropped, without orphaning their rows")
    func phoneEditRemovesDroppedChildren() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let clock = TestClock()
        var sessionID = UUID()
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: clock)
            var (active, bench, _) = try startedSession(in: store, clock: clock)
            sessionID = active.id
            let benchItemID = try #require(active.items.first { $0.exerciseID == bench.id }?.id)
            for index in 0..<3 {
                clock.advance(by: 180)
                try SessionMutator.logSet(
                    itemID: benchItemID, weight: Weight(kg: 80), reps: 5 - index,
                    in: &active, clock: clock
                )
            }
            try SessionMutator.finish(&active, clock: clock)
            try store.saveActiveSession(active)

            // The §6 editor deletes the mis-logged last set and the whole
            // second exercise the lifter never actually performed.
            var edited = try #require(try store.session(id: sessionID))
            edited.items[0].sets.removeLast()
            edited.items.removeLast()
            try store.applyPhoneEdit(edited)
        }

        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)
        let stored = try #require(try reopened.session(id: sessionID))
        #expect(stored.items.count == 1)
        #expect(stored.items[0].sets.count == 2)
        #expect(stored.revision == 2)
        // Genuinely deleted, not merely detached from their parent.
        #expect(try rowCount(SessionItem.self, in: container) == 1)
        #expect(try rowCount(SetRecord.self, in: container) == 2)
    }

    @Test("applyPhoneEdit on an unknown session throws notFound and writes nothing")
    func phoneEditOnUnknownSessionThrowsNotFound() throws {
        let store = try makeStore()
        let ghost = SessionData(startedAt: Fixture.epoch, origin: .live)
        #expect(throws: BurlyStoreError.notFound(ghost.id)) {
            try store.applyPhoneEdit(ghost)
        }
        #expect(try store.session(id: ghost.id) == nil)
    }

    // MARK: - Rejection leaves nothing behind

    @Test("a rejected saveActiveSession leaves nothing pending: an unrelated successful save afterwards cannot commit the rejected graph")
    func rejectedSaveLeavesNoResidue() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let ghostExerciseID = UUID()
        var brokenSessionID = UUID()
        let survivor = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])

        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: TestClock())
            let bench = Fixture.exercise(name: "Bench Press")
            try store.createExercise(bench)
            let routine = Fixture.routine(over: [bench])
            var active = SessionBuilder.session(from: routine, clock: TestClock())
            brokenSessionID = active.id
            // A picker handed the engine an exercise the watch catalog has
            // not received yet — the payload is well-formed, the reference
            // is not.
            active.session.items[0].exerciseID = ghostExerciseID

            #expect(throws: BurlyStoreError.missingExercise(ghostExerciseID)) {
                try store.saveActiveSession(active)
            }

            // The hazard the review named: an unrelated successful call
            // saves the same context. If the rejected session were still
            // pending, this is where it would silently commit.
            try store.createExercise(survivor)
        }

        let container = try BurlyContainer.make(.watch, at: .file(url))
        let reopened = SwiftDataStore(container: container)
        #expect(try reopened.exercise(id: survivor.id) == survivor)
        #expect(try reopened.session(id: brokenSessionID) == nil)
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionItem.self, in: container) == 0)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 0)
        #expect(try reopened.resumableActiveSession() == nil)
    }

    @Test("retrying the rejected session under the same UUID succeeds once the exercise exists — the failure left no ghost to collide with")
    func retryingTheSameSessionIDSucceedsAfterTheRejection() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        var active = SessionBuilder.session(from: routine, clock: TestClock())

        let latecomer = Fixture.exercise(name: "Machine Press")
        active.session.items[0].exerciseID = latecomer.id
        #expect(throws: BurlyStoreError.missingExercise(latecomer.id)) {
            try store.saveActiveSession(active)
        }

        // The picker's placeholder finally lands, and the same session id
        // is retried. A pending rejected parent would surface here as a
        // spurious `.duplicateID`.
        try store.createExercise(latecomer)
        try store.saveActiveSession(active)

        let stored = try #require(try store.session(id: active.id))
        #expect(stored.items.map(\.exerciseID) == [latecomer.id])
    }

    @Test("a malformed ActiveSession is refused whole, with the violations named")
    func malformedActiveSessionIsRefused() throws {
        let store = try makeStore(.watch)
        var (active, _, _) = try startedSession(in: store)

        // An item with no plan: I3's bijection broken. The §2 engine cannot
        // produce this; a hand-assembled or partially-decoded value can, and
        // persisting it would hand Resume a page with no set slots.
        let orphanID = UUID()
        active.session.items.append(
            SessionItemData(id: orphanID, exerciseID: nil, order: active.items.count)
        )

        #expect(throws: BurlyStoreError.self) {
            try store.saveActiveSession(active)
        }
        #expect(try store.session(id: active.id) == nil)
        #expect(try store.resumableActiveSession() == nil)
    }

    @Test("a set id already owned by another session is rejected rather than silently stolen by SwiftData's unique-merge")
    func setIDOwnedByAnotherSessionIsRejected() throws {
        let store = try makeStore(.watch)
        let clock = TestClock()
        var (first, bench, _) = try startedSession(in: store, clock: clock)
        let firstItemID = try #require(first.items.first { $0.exerciseID == bench.id }?.id)
        try SessionMutator.logSet(
            itemID: firstItemID, weight: Weight(kg: 100), reps: 5, in: &first, clock: clock
        )
        try store.saveActiveSession(first)
        let stolenSetID = try #require(first.item(firstItemID)?.sets.first?.id)

        let routine = Fixture.routine(name: "Second", over: [bench])
        var second = SessionBuilder.session(from: routine, clock: clock)
        second.session.items[0].sets = [
            SetRecordData(
                id: stolenSetID, order: 0, weight: Weight(kg: 20), reps: 1,
                completedAt: clock.now
            )
        ]

        #expect(throws: BurlyStoreError.duplicateID(stolenSetID)) {
            try store.saveActiveSession(second)
        }
        // The original set is untouched, and the intruding session was not
        // created at all.
        #expect(try store.session(id: second.id) == nil)
        let survivor = try #require(try store.session(id: first.id))
        #expect(survivor.items[0].sets.map(\.weightKg) == [100])
    }

    // MARK: - Bounded resume lookup (m1-06 review, M4 slice)

    @Test("resumableActiveSession finds the one in-flight session and ignores logged history")
    func resumeFindsOnlyTheInFlightSession() throws {
        let store = try makeStore(.watch)
        let clock = TestClock()
        let (_, bench, _) = try startedSession(in: store, clock: clock)

        // Three finished sessions sitting in the working set, plus the live
        // one. Resume must return the live one without materialising the
        // others.
        let routine = Fixture.routine(name: "History", over: [bench])
        for index in 0..<3 {
            var past = Fixture.session(
                from: routine, startedAt: Fixture.epoch.addingTimeInterval(Double(index) * 60)
            )
            past.state = .logged
            try store.createSession(past)
        }

        clock.advance(by: 10_000)
        let live = SessionBuilder.session(from: routine, clock: clock)
        try store.saveActiveSession(live)

        let resumed = try #require(try store.resumableActiveSession())
        #expect(resumed.id == live.id)
        #expect(resumed.session.state == .active)
        #expect(try store.sessions().count == 4)
    }

    @Test("resumableActiveSession is nil on an empty store and on one holding only logged sessions")
    func resumeIsNilWithNothingInFlight() throws {
        let store = try makeStore(.watch)
        #expect(try store.resumableActiveSession() == nil)

        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        var logged = Fixture.session(from: routine)
        logged.state = .logged
        try store.createSession(logged)

        #expect(try store.resumableActiveSession() == nil)
    }

    @Test("deleting a session takes its journal with it — Discard leaves no Resume pointer into nothing")
    func deletingASessionRetiresItsJournal() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let store = SwiftDataStore(container: container, clock: TestClock())
        let (active, _, _) = try startedSession(in: store)
        try store.saveActiveSession(active)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 1)

        try store.deleteSession(id: active.id)

        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 0)
        #expect(try store.resumableActiveSession() == nil)
        #expect(try store.activeSession(id: active.id) == nil)
    }

    /// Pins a measured SwiftData limitation, not a Burly design choice.
    ///
    /// The obvious bounded Resume query is
    /// `#Predicate<Session> { $0.state == .active }` with `fetchLimit = 1`.
    /// SwiftData rejects it at *runtime* — it compiles fine — which is why
    /// `resumableActiveSession()` goes through the `ActiveSessionJournal`
    /// index instead of predicating on the enum directly.
    ///
    /// If a future SwiftData starts supporting it, this test fails: delete
    /// the journal indirection from `resumableActiveSession()` and the
    /// paragraph explaining it in Models/ActiveSessionJournal.swift.
    @Test("SwiftData cannot predicate on SessionState — the reason the resume lookup is indexed by the journal")
    func swiftDataCannotPredicateOnSessionState() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let store = SwiftDataStore(container: container, clock: TestClock())
        let (active, _, _) = try startedSession(in: store)
        try store.saveActiveSession(active)

        let target = SessionState.active
        var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.state == target })
        descriptor.fetchLimit = 1

        #expect(throws: (any Error).self) {
            try ModelContext(container).fetch(descriptor)
        }
    }
}
