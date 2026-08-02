// SPDX-License-Identifier: GPL-3.0-or-later
// m5-01 — the bounded phone-shell existence/count queries added in the fix
// round for review finding 3 (the shell must establish empty states and a
// workout count without hydrating full graphs). These tests pin the two
// queries' semantics: `hasRoutines()` answers existence from the routine
// table (archived routines are not "there"), and `loggedSessionCount()`
// counts `.logged` sessions only — an `.active` workout is not history yet,
// exactly as `sessions(state:)` documents.

import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m5-01 — hasRoutines / loggedSessionCount: bounded phone-shell queries")
struct ShellQueryTests {

    // MARK: - hasRoutines

    @Test("hasRoutines is false on an empty phone store")
    func hasRoutinesFalseOnEmptyStore() throws {
        let store = try makeStore()
        #expect(try store.hasRoutines() == false)
    }

    @Test("hasRoutines is true once a routine exists, and false again after it is archived")
    func hasRoutinesTracksArchiveState() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(name: "Push A", over: [bench])
        try store.createRoutine(routine)

        #expect(try store.hasRoutines())

        try store.archiveRoutine(id: routine.id, at: Fixture.epoch)
        #expect(try store.hasRoutines() == false)
    }

    @Test("hasRoutines ignores archived routines beside an active one")
    func hasRoutinesSeesAnyNonArchived() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let archived = Fixture.routine(name: "Old Push", over: [bench])
        try store.createRoutine(archived)
        try store.archiveRoutine(id: archived.id, at: Fixture.epoch)
        #expect(try store.hasRoutines() == false)

        try store.createRoutine(Fixture.routine(name: "Current Push", over: [bench]))
        #expect(try store.hasRoutines())
    }

    // MARK: - loggedSessionCount

    @Test("loggedSessionCount is zero on an empty phone store")
    func countZeroOnEmptyStore() throws {
        let store = try makeStore()
        #expect(try store.loggedSessionCount() == 0)
    }

    @Test("loggedSessionCount counts every .logged session regardless of origin (spec §7 acceptance #2 shape)")
    func countIncludesLoggedSessionsOfAnyOrigin() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let routine = Fixture.routine(name: "Push A", over: [bench])
        try store.createRoutine(routine)

        var live = Fixture.session(from: routine, startedAt: Fixture.epoch)
        live.origin = .live
        try store.createSession(live)

        var imported = Fixture.session(
            from: routine,
            startedAt: Fixture.epoch.addingTimeInterval(3600)
        )
        imported.origin = .hevyImport
        try store.createSession(imported)

        #expect(try store.loggedSessionCount() == 2)
    }

    @Test("loggedSessionCount excludes an .active session — a workout in flight is not history yet")
    func countExcludesActiveSession() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(name: "Push A", over: [bench])

        // `.active` sessions can only enter through `saveActiveSession`
        // (m1-06 review round D); `createSession` refuses them.
        try store.saveActiveSession(Fixture.activeSession(from: routine))
        #expect(try store.loggedSessionCount() == 0)

        try store.createSession(Fixture.session(from: routine))
        #expect(try store.loggedSessionCount() == 1)
    }
}
