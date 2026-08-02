// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — `applyReplicatedSession(_:)`, the session counterpart to
// `applyRoutineSnapshot(_:)` (m1-06 fix round A's local-authoring vs
// replicated-apply split, extended to sessions here). These tests pin the
// store-level contract the `BurlyPhoneSync` session-ingest executor is
// built on: create-when-absent takes the payload's revision verbatim,
// replace-when-newer overwrites (never increments) the stored revision,
// and an incoming revision <= stored is a byte-for-byte no-op — no read
// beyond the recheck, no mutation, no save.
import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m4-04 — applyReplicatedSession: the session replicated-apply surface")
struct ReplicatedSessionApplyTests {

    @Test("absent session: creates it, taking the payload's revision verbatim")
    func createsWhenAbsent() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let incoming = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let returned = try store.applyReplicatedSession(incoming)

        #expect(returned == 1)
        #expect(try store.session(id: incoming.id) == incoming)
    }

    @Test("a higher incoming revision replaces the stored graph and overwrites the revision verbatim, not by incrementing")
    func replacesWhenIncomingRevisionIsHigher() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let original = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(original)

        var edited = original
        edited.notes = "edited elsewhere"
        edited.revision = 5

        let returned = try store.applyReplicatedSession(edited)

        #expect(returned == 5)
        let stored = try #require(try store.session(id: original.id))
        #expect(stored.revision == 5)
        #expect(stored.notes == "edited elsewhere")
    }

    @Test("an incoming revision equal to the stored one is a no-op: unchanged content, unchanged revision")
    func noOpWhenRevisionIsEqual() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let original = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(original)

        var stale = original
        stale.notes = "must not land"

        let returned = try store.applyReplicatedSession(stale)

        #expect(returned == 1)
        let stored = try #require(try store.session(id: original.id))
        #expect(stored == original)
        #expect(stored.notes == nil)
    }

    @Test("an incoming revision lower than the stored one is a no-op — the §5 drop-silently rule")
    func noOpWhenRevisionIsLower() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let original = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(original)
        _ = try store.applyPhoneEdit(original) // stored revision now 2

        var ghost = original
        ghost.revision = 1
        ghost.notes = "a stale watch redelivery"

        let returned = try store.applyReplicatedSession(ghost)

        #expect(returned == 2)
        let stored = try #require(try store.session(id: original.id))
        #expect(stored.revision == 2)
        #expect(stored.notes == nil)
    }

    @Test("refuses an .active incoming payload — only saveActiveSession may create one")
    func refusesActiveIncomingPayload() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        var active = Fixture.session(from: routine, startedAt: Fixture.epoch, state: .active)
        active.revision = 1

        #expect(throws: BurlyStoreError.activeSessionRequiresSaveActiveSession(sessionID: active.id)) {
            try store.applyReplicatedSession(active)
        }
        #expect(try store.session(id: active.id) == nil)
    }

    @Test("a higher-revision replica winning over a stored .active row retires its journal — the row is no longer resumable")
    func replacingAnActiveRowRetiresItsJournal() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let active = Fixture.activeSession(from: routine, startedAt: Fixture.epoch)
        try store.saveActiveSession(active)
        #expect(try store.activeSession(id: active.id) != nil)

        var replacement = active.session
        replacement.state = .logged
        replacement.endedAt = Fixture.epoch.addingTimeInterval(1_800)
        replacement.revision = 7

        let returned = try store.applyReplicatedSession(replacement)

        #expect(returned == 7)
        let stored = try #require(try store.session(id: active.id))
        #expect(stored.state == .logged)
        #expect(stored.revision == 7)
        // No journal survives — a Resume pointer at a finished row would be
        // exactly the class of bug `applyPhoneEdit`'s same rule prevents.
        #expect(try store.activeSession(id: active.id) == nil)
        #expect(try store.resumableActiveSession() == nil)
    }

    @Test("a dangling exercise reference is rejected before anything is touched, on both the create and replace branches")
    func danglingExerciseReferenceIsRejected() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let ghostExerciseID = UUID()
        let broken = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: ghostExerciseID, order: 0)]
        )
        #expect(throws: BurlyStoreError.missingExercise(ghostExerciseID)) {
            try store.applyReplicatedSession(broken)
        }
        #expect(try store.session(id: broken.id) == nil)

        // Now against an existing stored row, on the replace branch.
        let original = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(original)
        var brokenReplacement = original
        brokenReplacement.revision = 2
        brokenReplacement.items = [SessionItemData(exerciseID: ghostExerciseID, order: 0)]
        #expect(throws: BurlyStoreError.missingExercise(ghostExerciseID)) {
            try store.applyReplicatedSession(brokenReplacement)
        }
        // Untouched — the rejected replace left the original in place.
        #expect(try store.session(id: original.id) == original)
    }

    @Test("replaying the identical payload twice converges: same result, no throw, no double-mutation")
    func replayingTheIdenticalPayloadConverges() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let incoming = Fixture.session(from: routine, startedAt: Fixture.epoch)

        let first = try store.applyReplicatedSession(incoming)
        let second = try store.applyReplicatedSession(incoming)

        #expect(first == 1)
        #expect(second == 1)
        #expect(try store.session(id: incoming.id) == incoming)
    }
}
