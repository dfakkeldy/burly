// SPDX-License-Identifier: GPL-3.0-or-later
// m6-01 fix round 2, review item 3 — the blessed integration path
// (`BurlyStore.exerciseProgression(exerciseID:displayRange:)`) against a
// real store, reproducing the round-2 review's exact concrete scenario: an
// old, out-of-range session's all-time record must suppress a false PR for
// a recent in-range session, and it must do so with no help from the
// caller — the caller here only ever asks for `displayRange`, never
// touches the all-time fetch itself. `ExerciseProgressionStatsTests`
// already pins the pure-function half of this (feeding it hand-built
// all-time points); this file pins that the *store-backed* path actually
// wires that precondition correctly, since BurlyCore has no store to
// verify it against on its own.
import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@MainActor
@Suite("m6-01 fix round 2 — BurlyStore.exerciseProgression: the blessed all-time-then-filter path")
struct ExerciseProgressionIntegrationTests {
    private func loggedSession(
        exercise: ExerciseData,
        startedAt: Date,
        weightKg: Double,
        reps: Int
    ) -> SessionData {
        let routine = Fixture.routine(over: [exercise])
        var session = Fixture.session(from: routine, startedAt: startedAt)
        session.origin = .live
        let itemID = session.items[0].id
        return session.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: weightKg), reps: reps, completedAt: startedAt),
            toItem: itemID
        )
    }

    @Test("an out-of-range all-time PR suppresses a false PR for a recent session inside the displayed range")
    func rangeRelativeFalsePRIsSuppressedByAllTimeFetch() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let oldDate = Fixture.epoch.addingTimeInterval(-500 * 86_400)
        let recentDate = Fixture.epoch

        // All-time best on both series: e1RM 120×(1+5/30) = 140, far
        // outside any plausible displayed range.
        try store.createSession(loggedSession(exercise: bench, startedAt: oldDate, weightKg: 120, reps: 5))
        // Beats neither all-time record (100 < 120; e1RM 116.67 < 140), but
        // would look like a fresh PR to a caller that (wrongly) fetched
        // only the displayed range.
        try store.createSession(loggedSession(exercise: bench, startedAt: recentDate, weightKg: 100, reps: 5))

        let displayRange = recentDate.addingTimeInterval(-1)...recentDate.addingTimeInterval(1)
        let result = try store.exerciseProgression(exerciseID: bench.id, displayRange: displayRange)

        // The all-time points include both sessions (unfiltered) ...
        #expect(result.points.count == 2)
        // ... but the recent session is not an all-time PR on either
        // series, so it must not appear in the range-filtered records —
        // this is exactly the false positive review item 3 called out as
        // reachable when the all-time fetch isn't wired correctly.
        #expect(result.records.isEmpty)
    }

    @Test("a genuine improvement inside the displayed range still reports as a PR")
    func genuineInRangeImprovementStillReportsAsAPR() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let oldDate = Fixture.epoch.addingTimeInterval(-500 * 86_400)
        let recentDate = Fixture.epoch

        try store.createSession(loggedSession(exercise: bench, startedAt: oldDate, weightKg: 100, reps: 5))
        // Beats both all-time records.
        try store.createSession(loggedSession(exercise: bench, startedAt: recentDate, weightKg: 130, reps: 5))

        let displayRange = recentDate.addingTimeInterval(-1)...recentDate.addingTimeInterval(1)
        let result = try store.exerciseProgression(exerciseID: bench.id, displayRange: displayRange)

        #expect(result.records.count == 2) // both topWeight and estimatedOneRepMax
        #expect(result.records.allSatisfy { displayRange.contains($0.date) })
    }

    @Test("displayRange: nil (the default) returns every all-time record, matching the pure function's own default")
    func nilDisplayRangeReturnsEveryRecord() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch, weightKg: 100, reps: 5))
        try store.createSession(loggedSession(exercise: bench, startedAt: Fixture.epoch.addingTimeInterval(86_400), weightKg: 110, reps: 5))

        let result = try store.exerciseProgression(exerciseID: bench.id)
        #expect(result.records.count == 4) // both series, both sessions
    }
}
