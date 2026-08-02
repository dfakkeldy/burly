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

@MainActor
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

    // MARK: - Major 8: the existing-row no-op check runs BEFORE the .active guard

    @Test("major 8 — a stale .active replica at revision <= stored is a silent no-op, not a thrown .active refusal")
    func staleActiveReplicaIsASilentNoOp() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        // A stored, finished session already at revision 2.
        let original = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(original)
        _ = try store.applyPhoneEdit(original)
        #expect(try store.session(id: original.id)?.revision == 2)

        // A stale, `.active`-shaped replica at revision 1 arrives — the
        // shape the old ordering (guard `.active` first) would have thrown
        // `.activeSessionRequiresSaveActiveSession` on, even though §5's
        // rule ("incoming revision <= stored is a no-op") already settles
        // this payload before its `.active`-ness is even relevant.
        var staleActive = original
        staleActive.state = .active
        staleActive.revision = 1

        let returned = try store.applyReplicatedSession(staleActive)

        #expect(returned == 2, "the no-op must return the unchanged stored revision, not throw")
        let stored = try #require(try store.session(id: original.id))
        #expect(stored.state == .logged, "untouched — the stale payload never reaches the .active guard or the graph reconciliation")
        #expect(stored.revision == 2)
    }

    // MARK: - Major 7: revision range validation

    @Test("major 7 — an out-of-range revision (zero, negative, or above the maximum) is refused with .invalidRevision before anything is touched")
    func outOfRangeRevisionIsRefused() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        for badRevision in [0, -1, SessionData.maximumRevision + 1] {
            var broken = Fixture.session(from: routine, startedAt: Fixture.epoch)
            broken.revision = badRevision
            #expect(throws: BurlyStoreError.invalidRevision(sessionID: broken.id, revision: badRevision)) {
                try store.applyReplicatedSession(broken)
            }
            #expect(try store.session(id: broken.id) == nil)
        }
    }

    @Test("major 7 — applyPhoneEdit refuses to increment a session already at maximumRevision with a thrown domain error, not a trap")
    func applyPhoneEditRefusesToOverflowPastMaximumRevision() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        // Reach `maximumRevision` via the replicated-apply path, which
        // takes a revision verbatim rather than incrementing — the only
        // way to plant a session already at the bound without looping
        // `applyPhoneEdit` a billion times.
        var atBound = Fixture.session(from: routine, startedAt: Fixture.epoch)
        atBound.revision = SessionData.maximumRevision
        _ = try store.applyReplicatedSession(atBound)
        #expect(try store.session(id: atBound.id)?.revision == SessionData.maximumRevision)

        // The line this test exists for: if this ever called `stored
        // .revision += 1` unconditionally again, and `maximumRevision`
        // were ever raised to `Int.max`, this would trap the process
        // instead of throwing. Pinned at the current bound, which is far
        // below `Int.max` precisely so this stays a normal, catchable
        // failure forever.
        #expect(throws: BurlyStoreError.invalidRevision(sessionID: atBound.id, revision: SessionData.maximumRevision)) {
            _ = try store.applyPhoneEdit(atBound)
        }
        // Untouched — the refused edit left the stored revision exactly
        // where it was.
        #expect(try store.session(id: atBound.id)?.revision == SessionData.maximumRevision)
    }

    @Test("major 7 — createSession also refuses an out-of-range revision before touching a row")
    func createSessionRefusesOutOfRangeRevision() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        var broken = Fixture.session(from: routine, startedAt: Fixture.epoch)
        broken.revision = -1
        #expect(throws: BurlyStoreError.invalidRevision(sessionID: broken.id, revision: -1)) {
            try store.createSession(broken)
        }
        #expect(try store.session(id: broken.id) == nil)
    }

    // MARK: - Major 1: placeholder upsert + session apply, one transaction

    @Test("major 1 — a placeholder exercise the session references upserts and the session applies in the SAME transaction")
    func placeholderAndSessionApplyAtomicallyOnSuccess() throws {
        let store = try makeStore()
        let placeholder = Fixture.exercise(name: "Custom", origin: .custom)

        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: placeholder.id, order: 0)]
        )

        let returned = try store.applyReplicatedSession(session, upsertingPlaceholderExercises: [placeholder])

        #expect(returned == 1)
        #expect(try store.exercise(id: placeholder.id) == placeholder)
        #expect(try store.session(id: session.id)?.items.first?.exerciseID == placeholder.id)
    }

    @Test("major 1 — a rejected delivery rolls the placeholder back too: nothing survives, not even the placeholder alone")
    func placeholderDoesNotSurviveARejectedDelivery() throws {
        let store = try makeStore()
        let placeholder = Fixture.exercise(name: "Custom", origin: .custom)
        let unrelatedGhostID = UUID()

        // The session references BOTH the legitimate placeholder AND an
        // unrelated dangling exercise — the placeholder alone would
        // resolve fine (it's in `placeholders`), but the ghost reference
        // fails preflight, which must roll back everything staged in this
        // call, including the placeholder insert that came before it.
        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(exerciseID: placeholder.id, order: 0),
                SessionItemData(exerciseID: unrelatedGhostID, order: 1)
            ]
        )

        #expect(throws: BurlyStoreError.self) {
            try store.applyReplicatedSession(session, upsertingPlaceholderExercises: [placeholder])
        }

        #expect(try store.exercise(id: placeholder.id) == nil, "the placeholder must not survive as committed residue")
        #expect(try store.session(id: session.id) == nil)

        // The rejection must leave nothing pending for a later, unrelated
        // save to commit (the m1-06 review M1 hazard this fix closes) —
        // proven by making an unrelated successful call afterward and
        // checking the placeholder still never appears.
        try store.createExercise(Fixture.exercise(name: "Unrelated"))
        #expect(try store.exercise(id: placeholder.id) == nil)
    }

    @Test("major 1 — an already-known placeholder exercise is never overwritten, even when bundled with the session apply")
    func knownPlaceholderIsNotOverwrittenViaTheBundledPath() throws {
        let store = try makeStore()
        let named = Fixture.exercise(name: "Renamed by Dan", origin: .custom)
        try store.createExercise(named)

        let staleCopy = Fixture.exercise(id: named.id, name: "Custom", origin: .custom)
        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: named.id, order: 0)]
        )

        _ = try store.applyReplicatedSession(session, upsertingPlaceholderExercises: [staleCopy])

        let stored = try #require(try store.exercise(id: named.id))
        #expect(stored.name == "Renamed by Dan")
    }
}
