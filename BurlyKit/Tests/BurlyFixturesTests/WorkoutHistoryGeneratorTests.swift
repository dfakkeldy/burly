// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("WorkoutHistoryGenerator")
struct WorkoutHistoryGeneratorTests {
    /// A fixed, plausible-modern anchor date, used instead of any notion of
    /// "today" so tests stay deterministic regardless of when they run.
    private static let referenceStartDate = CivilDate(year: 2025, month: 6, day: 15)

    @Test("same seed produces identical sessions")
    func determinism() {
        let a = WorkoutHistoryGenerator.generate(seed: 42, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        let b = WorkoutHistoryGenerator.generate(seed: 42, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        #expect(a == b)
    }

    @Test("different seeds produce different sessions")
    func seedSensitivity() {
        let a = WorkoutHistoryGenerator.generate(seed: 1, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        let b = WorkoutHistoryGenerator.generate(seed: 2, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        #expect(a != b)
    }

    @Test("produces exactly the requested number of sessions")
    func rowCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 7, sessionCount: 50, spanDays: 180, startDate: Self.referenceStartDate)
        #expect(sessions.count == 50)
    }

    @Test("zero-count request yields no sessions")
    func zeroCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 7, sessionCount: 0, spanDays: 180, startDate: Self.referenceStartDate)
        #expect(sessions.isEmpty)
    }

    @Test("includes at least one 0 kg bodyweight set across a large sample")
    func bodyweightSetsPresent() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 99, sessionCount: 200, spanDays: 365, startDate: Self.referenceStartDate)
        let hasBodyweightSet = sessions
            .flatMap(\.exercises)
            .flatMap(\.sets)
            .contains { $0.weightKg == 0 }
        #expect(hasBodyweightSet)
    }

    @Test("every set has at least one rep and non-negative weight")
    func plausibleValues() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 3, sessionCount: 40, spanDays: 120, startDate: Self.referenceStartDate)
        for set in sessions.flatMap(\.exercises).flatMap(\.sets) {
            #expect(set.reps > 0)
            #expect(set.weightKg >= 0)
        }
    }

    @Test("sessions are returned in ascending date order")
    func dateOrdering() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 11, sessionCount: 60, spanDays: 200, startDate: Self.referenceStartDate)
        let ordinals = sessions.map(\.start.ordinal)
        #expect(ordinals == ordinals.sorted())
    }

    @Test("every session stays within the requested date span, anchored at startDate")
    func spanRespected() {
        let spanDays = 45
        let sessions = WorkoutHistoryGenerator.generate(seed: 5, sessionCount: 30, spanDays: spanDays, startDate: Self.referenceStartDate)
        for session in sessions {
            #expect(session.start.dayCount >= Self.referenceStartDate.dayCount - spanDays)
            #expect(session.start.dayCount <= Self.referenceStartDate.dayCount)
        }
    }

    @Test("output is deterministic given (seed, startDate): changing startDate shifts the range, not just count")
    func startDateAnchorsRange() {
        let earlyAnchor = CivilDate(year: 2020, month: 1, day: 1)
        let lateAnchor = CivilDate(year: 2025, month: 6, day: 15)
        let early = WorkoutHistoryGenerator.generate(seed: 30, sessionCount: 20, spanDays: 30, startDate: earlyAnchor)
        let late = WorkoutHistoryGenerator.generate(seed: 30, sessionCount: 20, spanDays: 30, startDate: lateAnchor)
        #expect(early.allSatisfy { $0.start.dayCount <= earlyAnchor.dayCount })
        #expect(late.allSatisfy { $0.start.dayCount <= lateAnchor.dayCount })
        #expect(early.map(\.start.dayCount) != late.map(\.start.dayCount))
    }

    // MARK: - HistoryGenerationOptions knobs

    @Test("warmupSetProbability of 0 (the default) never produces a warmup set")
    func noWarmupsByDefault() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 12, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        let hasWarmup = sessions.flatMap(\.exercises).flatMap(\.sets).contains { $0.isWarmup }
        #expect(!hasWarmup)
    }

    @Test("warmupSetProbability of 1 adds warmup sets, rendered with set_type \"warmup\"")
    func warmupSetsAppearWhenEnabled() {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 12, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(warmupSetProbability: 1.0)
        )
        let warmupSets = sessions.flatMap(\.exercises).flatMap(\.sets).filter(\.isWarmup)
        #expect(!warmupSets.isEmpty)
    }

    @Test("progressiveOverloadEnabled trends the recurring exercise's weight upward over time")
    func progressiveOverloadTrendsUpward() {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 55, sessionCount: 60, spanDays: 180, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(progressiveOverloadEnabled: true)
        )

        var occurrencesByTitle: [String: [(dayCount: Int, weight: Double)]] = [:]
        for session in sessions {
            for exercise in session.exercises {
                guard let weight = exercise.sets.last?.weightKg, weight > 0 else { continue }
                occurrencesByTitle[exercise.title, default: []].append((session.start.dayCount, weight))
            }
        }

        guard let recurring = occurrencesByTitle.values.max(by: { $0.count < $1.count }),
              recurring.count >= 6 else {
            Issue.record("expected a recurring exercise with several occurrences")
            return
        }

        let sorted = recurring.sorted { $0.dayCount < $1.dayCount }
        let half = sorted.count / 2
        let firstHalfAvg = sorted.prefix(half).map(\.weight).reduce(0, +) / Double(half)
        let secondHalfAvg = sorted.suffix(half).map(\.weight).reduce(0, +) / Double(half)
        #expect(secondHalfAvg > firstHalfAvg)
    }

    @Test("failedSetProbability of 1 makes every set 0 reps")
    func failedSetProbabilityForcesZeroReps() {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 9, sessionCount: 10, spanDays: 30, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(failedSetProbability: 1.0)
        )
        let allZero = sessions.flatMap(\.exercises).flatMap(\.sets).allSatisfy { $0.reps == 0 }
        #expect(allZero)
    }

    @Test("emptySessionProbability of 1 yields sessions with zero exercises")
    func emptySessionProbabilityForcesEmptySessions() {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 4, sessionCount: 10, spanDays: 30, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(emptySessionProbability: 1.0)
        )
        #expect(sessions.allSatisfy { $0.exercises.isEmpty })
    }

    @Test("emptySessionProbability of 0 (the default) never produces an empty session")
    func noEmptySessionsByDefault() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 4, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        #expect(sessions.allSatisfy { !$0.exercises.isEmpty })
    }

    @Test("repeatedExerciseProbability of 1 logs a repeated exercise at a different weight, never a superset/dropset")
    func repeatedExerciseAtDifferentWeight() {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 61, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate,
            options: HistoryGenerationOptions(repeatedExerciseProbability: 1.0)
        )

        let hasRepeatAtDifferentWeight = sessions.contains { session in
            let titles = session.exercises.map(\.title)
            let duplicateTitles = Set(titles.filter { title in titles.filter { $0 == title }.count > 1 })
            guard let duplicateTitle = duplicateTitles.first else { return false }
            let weights = Set(
                session.exercises
                    .filter { $0.title == duplicateTitle }
                    .compactMap { $0.sets.last?.weightKg }
            )
            return weights.count > 1
        }
        #expect(hasRepeatAtDifferentWeight)

        // Each exercise entry is still just a flat list of sets at one
        // weight — repetition is two distinct FixtureExercise entries, never
        // multiple weights folded into a single entry's sets (a dropset).
        for session in sessions {
            for exercise in session.exercises {
                let distinctWeights = Set(exercise.sets.filter { !$0.isWarmup }.map(\.weightKg))
                #expect(distinctWeights.count <= 1)
            }
        }
    }
}
