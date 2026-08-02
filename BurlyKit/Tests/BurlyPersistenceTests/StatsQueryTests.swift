// SPDX-License-Identifier: GPL-3.0-or-later
// m6-01 — the bounded §7 stats query surface added to close the m1-06
// adversarial-review finding that stats must not build on `sessions()`'s
// unbounded, whole-graph fetch (session → items → sets fault
// amplification). These tests exercise the *store's* half of the contract:
// date bounds, exercise scoping, `.active`-session exclusion, and that a
// `.hevyImport` session counts identically to a `.live` one (spec §7
// acceptance #2). The computation half (Epley, weekly volume, fractional
// split, consistency) is fixture-truth tested in BurlyCoreTests/Stats —
// this file never asserts a computed chart number.
//
// m6-01 fix round 2, review item 7: the bounded-query guarantee is now
// enforced by API shape rather than a runtime nil-check — `loggedSetSlices`
// requires either a concrete `exerciseID` or a validated `TrailingWindow`,
// and `loggedSessionDates`'s `since` is a plain non-optional `Date`, with
// the genuinely-unbounded case promoted to its own named method,
// `allLoggedSessionDates()`. There is no longer a "call it with everything
// nil and expect a thrown error" scenario to test — the old all-nil call
// simply cannot be written anymore, which is the point (see `BurlyStore`'s
// stats-queries doc and `BurlyStoreError`'s doc on why `unboundedStatsQuery`
// no longer exists).
import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m6-01 — loggedSetSlices / loggedSessionDates: bounded stats queries")
struct StatsQueryTests {
    /// A fixed, deterministic calendar for the `TrailingWindow`-based
    /// queries — same rationale as every other §7 fixture in this
    /// codebase: determinism comes from the test pinning its inputs, not
    /// from production code (or the test) reaching for `.current`.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

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

    // MARK: - Date bounds (exercise-bounded form)

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

        let slices = try store.loggedSetSlices(exerciseID: bench.id, since: since, through: through)
        #expect(slices.map(\.set.weight.kg).sorted() == [20, 30])
    }

    @Test("through: nil is unbounded above")
    func throughNilIsUnboundedAbove() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantFuture, completedAt: .distantFuture, weightKg: 20, reps: 1))

        let all = try store.loggedSetSlices(exerciseID: bench.id, since: Fixture.epoch.addingTimeInterval(-1), through: nil)
        #expect(all.count == 2)
    }

    @Test("since: nil is unbounded below — the PR chart's all-time, one-exercise shape")
    func sinceNilIsUnboundedBelow() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantPast, completedAt: .distantPast, weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantFuture, completedAt: .distantFuture, weightKg: 20, reps: 1))

        let all = try store.loggedSetSlices(exerciseID: bench.id, since: nil, through: nil)
        #expect(all.count == 2)
    }

    @Test("loggedSessionDates(since:through:) bounds by startedAt the same way")
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

    @Test("exerciseID scopes loggedSetSlices(exerciseID:since:through:) to one exercise's sets")
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
    }

    /// Pins the runner-predicate fix (m6-01 fix — see
    /// `setRecordFilterPredicate`'s doc): a `SessionItem` with no exercise
    /// reference at all is a legitimate §1 state (spec allows
    /// `exercise: Exercise?`; see `StoreAPISurfaceTests`' "a nil exercise
    /// reference is allowed"), and an exercise-bound query has to exclude
    /// its sets without crashing. The predicate now force-unwraps
    /// `sessionItem!.exercise!.id` instead of optional-chaining through
    /// both hops — this is the case that would trap if CoreData evaluated
    /// that force-unwrap the way a plain Swift closure over faulted objects
    /// would. It does not: SwiftData compiles the two-hop force-unwrap to a
    /// SQL join, and a nil link just has no join partner, so the row is
    /// excluded like any other non-match.
    @Test("exerciseID scoping excludes a set whose session item has no exercise — nil relationship, not a crash")
    func exerciseIDScopingExcludesNilExerciseSessionItems() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(
                    exerciseID: bench.id,
                    order: 0,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch)]
                ),
                SessionItemData(
                    exerciseID: nil,
                    order: 1,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 999), reps: 1, completedAt: Fixture.epoch)]
                ),
            ]
        )
        try store.createSession(session)

        let slices = try store.loggedSetSlices(exerciseID: bench.id, since: nil, through: nil)
        #expect(slices.map(\.set.weight.kg) == [100])
    }

    // MARK: - The all-exercises, TrailingWindow-bounded form (m6-01 fix round 2, review item 7)

    @Test("loggedSetSlices(window:through:calendar:) returns every exercise's sets within the trailing window")
    func trailingWindowFormReturnsEveryExercise() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        try store.createExercise(bench)
        try store.createExercise(row)
        let asOf = Fixture.epoch
        try store.createSession(loggedSession(exercise: bench, startedAt: asOf, completedAt: asOf, weightKg: 100, reps: 5))
        try store.createSession(loggedSession(exercise: row, startedAt: asOf, completedAt: asOf, weightKg: 60, reps: 8))
        // Well outside a 2-week trailing window.
        try store.createSession(loggedSession(exercise: bench, startedAt: asOf.addingTimeInterval(-30 * 86_400), completedAt: asOf.addingTimeInterval(-30 * 86_400), weightKg: 999, reps: 1))

        let slices = try store.loggedSetSlices(window: .weeks(2), through: asOf, calendar: Self.utc)
        #expect(slices.map(\.set.weight.kg).sorted() == [60, 100])
    }

    @Test("loggedSetSlices(window:through:calendar:) with .days(_:) bounds by a plain day count")
    func trailingWindowDaysForm() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let asOf = Fixture.epoch
        try store.createSession(loggedSession(exercise: bench, startedAt: asOf, completedAt: asOf, weightKg: 10, reps: 1))
        // 10 days back — outside a 5-day window.
        try store.createSession(loggedSession(exercise: bench, startedAt: asOf.addingTimeInterval(-10 * 86_400), completedAt: asOf.addingTimeInterval(-10 * 86_400), weightKg: 20, reps: 1))

        let slices = try store.loggedSetSlices(window: .days(5), through: asOf, calendar: Self.utc)
        #expect(slices.map(\.set.weight.kg) == [10])
    }

    // MARK: - allLoggedSessionDates (m6-01 fix round 2, review item 7)

    @Test("allLoggedSessionDates returns every .logged session's startedAt regardless of age")
    func allLoggedSessionDatesReturnsEverything() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: .distantPast, completedAt: .distantPast, weightKg: 10, reps: 1))
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 10, reps: 1))

        let dates = try store.allLoggedSessionDates()
        #expect(dates.sorted() == [.distantPast, Fixture.epoch])
    }

    @Test("allLoggedSessionDates still excludes .active sessions")
    func allLoggedSessionDatesExcludesActive() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 100, reps: 5))

        var active = SessionBuilder.session(from: routine, clock: TestClock(Fixture.epoch.addingTimeInterval(3_600)))
        try SessionMutator.logSet(
            itemID: active.session.items[0].id,
            weight: Weight(kg: 999),
            reps: 1,
            in: &active,
            clock: TestClock(Fixture.epoch.addingTimeInterval(3_600))
        )
        try store.saveActiveSession(active)

        #expect(try store.allLoggedSessionDates() == [Fixture.epoch])
    }

    // MARK: - State exclusion: an in-flight session is not history yet

    @Test("an .active session's sets do not appear in any stats query")
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

        let since = Fixture.epoch.addingTimeInterval(-1)
        let bySince = try store.loggedSetSlices(exerciseID: bench.id, since: since, through: nil)
        #expect(bySince.map(\.set.weight.kg) == [100]) // the 999 kg active set never appears

        let byWindow = try store.loggedSetSlices(window: .weeks(52), through: Fixture.epoch.addingTimeInterval(3_600), calendar: Self.utc)
        #expect(byWindow.map(\.set.weight.kg) == [100])

        let dates = try store.loggedSessionDates(since: since, through: nil)
        #expect(dates == [Fixture.epoch]) // the active session's startedAt never appears
    }

    // MARK: - Warmup is NOT filtered by the store (spec §7 exclusion is a computation concern)

    @Test("the store returns warmup sets too — BurlyCore's stats functions are what exclude them, not the query")
    func storeDoesNotFilterWarmups() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, completedAt: Fixture.epoch, weightKg: 40, reps: 5, isWarmup: true))

        let slices = try store.loggedSetSlices(exerciseID: bench.id, since: nil, through: nil)
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

        let dates = try store.loggedSessionDates(since: Fixture.epoch.addingTimeInterval(-1), through: nil)
        #expect(dates.count == 2)
    }
}
