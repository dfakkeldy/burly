// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("WorkoutHistoryGenerator")
struct WorkoutHistoryGeneratorTests {
    @Test("same seed produces identical sessions")
    func determinism() {
        let a = WorkoutHistoryGenerator.generate(seed: 42, sessionCount: 30, spanDays: 90)
        let b = WorkoutHistoryGenerator.generate(seed: 42, sessionCount: 30, spanDays: 90)
        #expect(a == b)
    }

    @Test("different seeds produce different sessions")
    func seedSensitivity() {
        let a = WorkoutHistoryGenerator.generate(seed: 1, sessionCount: 30, spanDays: 90)
        let b = WorkoutHistoryGenerator.generate(seed: 2, sessionCount: 30, spanDays: 90)
        #expect(a != b)
    }

    @Test("produces exactly the requested number of sessions")
    func rowCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 7, sessionCount: 50, spanDays: 180)
        #expect(sessions.count == 50)
    }

    @Test("zero-count request yields no sessions")
    func zeroCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 7, sessionCount: 0, spanDays: 180)
        #expect(sessions.isEmpty)
    }

    @Test("includes at least one 0 kg bodyweight set across a large sample")
    func bodyweightSetsPresent() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 99, sessionCount: 200, spanDays: 365)
        let hasBodyweightSet = sessions
            .flatMap(\.exercises)
            .flatMap(\.sets)
            .contains { $0.weightKg == 0 }
        #expect(hasBodyweightSet)
    }

    @Test("every set has at least one rep and non-negative weight")
    func plausibleValues() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 3, sessionCount: 40, spanDays: 120)
        for set in sessions.flatMap(\.exercises).flatMap(\.sets) {
            #expect(set.reps > 0)
            #expect(set.weightKg >= 0)
        }
    }

    @Test("sessions are returned in ascending date order")
    func dateOrdering() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 11, sessionCount: 60, spanDays: 200)
        let ordinals = sessions.map(\.start.ordinal)
        #expect(ordinals == ordinals.sorted())
    }

    @Test("every session stays within the requested date span")
    func spanRespected() {
        let spanDays = 45
        let sessions = WorkoutHistoryGenerator.generate(seed: 5, sessionCount: 30, spanDays: spanDays)
        for session in sessions {
            #expect(session.start.dayCount >= -spanDays)
            #expect(session.start.dayCount <= 0)
        }
    }
}
