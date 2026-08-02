// SPDX-License-Identifier: GPL-3.0-or-later
// m6-01 — the bounded §7 stats query surface added to close the m1-06
// adversarial-review finding that stats must not build on `sessions()`'s
// unbounded, whole-graph fetch (session → items → sets fault
// amplification). These tests exercise the *store's* half of the contract:
// date bounds, exercise scoping, `.active`-session exclusion, and that a
// `.hevyImport` session counts identically to a `.live` one (spec §7
// acceptance #2). The computation half (Epley, weekly volume, fractional
// split, consistency) is fixture-truth tested in
// BurlyCoreTests/Stats — this file never asserts a computed chart number.
import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m6-01 — loggedSetSlices / loggedSessionDates: bounded stats queries")
struct StatsQueryTests {

    /// A one-exercise routine, and a **finished** session over it with one
    /// set added at `completedAt`, ready for `createSession`.
    private func loggedSession(
        id: UUID = UUID(),
        exercise: ExerciseData,
        startedAt: Date,
        completedAt: Date,
        weightKg: Double,
        reps: Int,
        isWarmup: Bool = false,
        origin: SessionOrigin = .live
    ) -> SessionData {
        let routine = Fixture.routine(over: [exercise])
        var session = Fixture.session(id: id, from: routine, startedAt: startedAt)
        session.origin = origin
        let itemID = session.items[0].id
        return session.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: weightKg), reps: reps, isWarmup: isWarmup, completedAt: completedAt),
            toItem: itemID
        )
    }

    // MARK: - Date bounds

    @Test("since/through bound completedAt: a set outside the window is excluded, one at each edge is included")
    func dateBoundsAreInclusiveAtBothEdges() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let since = Fixture.epoch
        let through = Fixture.epoch.addingTimeInterval(100)

        try store.createSession(loggedSession(exercise: bench, startedAt: since.addingTimeInterval(-10), completedAt: since.addingTimeInterval(-1), weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: since, completedAt: since, weightKg: 20, reps: 2))
        try store.createSession(loggedSession(exercise: bench, startedAt: through, completedAt: through, weightKg: 30, reps: 3))
        try store.createSession(loggedSession(exercise: bench, startedAt: through.addingTimeInterval(10), completedAt: through.addingTimeInterval(1), weightKg: 40, reps: 4))

        let slices = try store.loggedSetSlices(exerciseID: nil, since: since, through: through)
        #expect(slices.map(\.set.weight.kg).sorted() == [20, 30])
    }

    @Test("since: nil is unbounded below; through: nil is unbounded above")
    func nilBoundsAreUnbounded() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantPast, completedAt: .distantPast, weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantFuture, completedAt: .distantFuture, weightKg: 20, reps: 1))

        let all = try store.loggedSetSlices(exerciseID: nil, since: nil, through: nil)
        #expect(all.count == 2)
    }

    @Test("loggedSessionDates bounds by startedAt the same way")
    func sessionDatesRespectBounds() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let inWindow = Fixture.epoch
        let outOfWindow = Fixture.epoch.addingTimeInterval(-1_000_000)
        try store.createSession(loggedSession(exercise: bench, startedAt: inWindow, completedAt: inWindow, weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: outOfWindow, completedAt: outOfWindow, weightKg: 10, reps: 1))

        let dates = try store.loggedSessionDates(since: Fixture.epoch.addingTimeInterval(-1), through: nil)
        #expect(dates == [inWindow])
    }

    // MARK: - Exercise scoping

    @Test("exerciseID scopes to one exercise's sets; nil returns every exercise's")
    func exerciseIDScopesResults() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 100, reps: 5))
        try store.createSession(loggedSession(exercise: row, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 60, reps: 8))

        let benchOnly = try store.loggedSetSlices(exerciseID: bench.id, since: nil, through: nil)
        #expect(benchOnly.map(\.set.weight.kg) == [100])
        #expect(benchOnly.allSatisfy { $0.exerciseID == bench.id })

        let everything = try store.loggedSetSlices(exerciseID: nil, since: nil, through: nil)
        #expect(everything.count == 2)
    }

    // MARK: - State exclusion: an in-flight session is not history yet

    @Test("an .active session's sets do not appear in either stats query")
    func activeSessionIsExcluded() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])

        // A finished session, so the store isn't empty.
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 100, reps: 5))

        // An in-flight session with a logged set, via the only legitimate
        // write path for `.active` (saveActiveSession) — see BurlyStore's
        // "There is no `logSet`" doc.
        var active = SessionBuilder.session(from: routine, clock: TestClock(Fixture.epoch.addingTimeInterval(3_600)))
        try SessionMutator.logSet(
            itemID: active.session.items[0].id,
            weight: Weight(kg: 999),
            reps: 1,
            in: &active,
            clock: TestClock(Fixture.epoch.addingTimeInterval(3_600))
        )
        try store.saveActiveSession(active)

        let slices = try store.loggedSetSlices(exerciseID: nil, since: nil, through: nil)
        #expect(slices.map(\.set.weight.kg) == [100]) // the 999 kg active set never appears

        let dates = try store.loggedSessionDates(since: nil, through: nil)
        #expect(dates == [Fixture.epoch]) // the active session's startedAt never appears
    }

    // MARK: - Warmup is NOT filtered by the store (spec §7 exclusion is a computation concern)

    @Test("the store returns warmup sets too — BurlyCore's stats functions are what exclude them, not the query")
    func storeDoesNotFilterWarmups() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 40, reps: 5, isWarmup: true))

        let slices = try store.loggedSetSlices(exerciseID: nil, since: nil, through: nil)
        #expect(slices.count == 1)
        #expect(slices[0].set.isWarmup == true)
    }

    // MARK: - Spec §7 acceptance #2: imported sessions count identically to live ones

    @Test("a .hevyImport session's sets and dates are returned exactly like a .live session's — the query does not discriminate by origin")
    func hevyImportSessionsCountIdenticallyToLiveOnes() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 100, reps: 5, origin: .live))
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch.addingTimeInterval(86_400), completedAt: Fixture.epoch.addingTimeInterval(86_400), weightKg: 100, reps: 5, origin: .hevyImport))

        let slices = try store.loggedSetSlices(exerciseID: bench.id, since: nil, through: nil)
        #expect(slices.count == 2)
        // Both sessions contribute the same weight/reps — nothing about the
        // returned `SetRecordSlice` even carries `origin`, which is the
        // point: there is no field left for a filter to key off of.
        #expect(slices.allSatisfy { $0.set.weight.kg == 100 && $0.set.reps == 5 })

        let dates = try store.loggedSessionDates(since: nil, through: nil)
        #expect(dates.count == 2)
    }
}
