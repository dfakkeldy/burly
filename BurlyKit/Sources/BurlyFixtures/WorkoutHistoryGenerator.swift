// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// Synthetic workout-history generator. Produces plausible-looking lifting
// sessions for use as test/preview data. All output is synthetic: exercise
// names come from a fixed built-in list, no real person's training history,
// body metrics, or identity is used or referenced anywhere in this module.
//
// Burly v1 is weight × reps only: fixtures deliberately do not model
// supersets or dropsets. Warmup sets do exist in the app's frozen schema
// (an `isWarmup` flag per set) and are covered here as an opt-in knob.
//
// Pure Swift, zero framework imports.

/// A single logged set. `weightKg` of 0 is the project-wide convention for a
/// bodyweight set (e.g. pull-ups, dips) rather than an external load.
/// `isWarmup` mirrors the app's frozen per-set schema flag.
public struct FixtureSet: Sendable, Equatable {
    /// kg by contract, same convention as `SetRecordData.weightKg`: this
    /// field is always kilograms, never pounds. Synthetic fixture data
    /// deliberately stays a plain `Double` here rather than routing
    /// through BurlyCore's `Weight` type — `BurlyFixtures` depends on
    /// nothing (see this file's header) and is not app/domain code; the
    /// `Weight` construction boundary (validated, pounds-safe) is a
    /// BurlyCore guarantee for real app data, not a requirement this
    /// generator's synthetic output needs to satisfy.
    public let weightKg: Double
    public let reps: Int
    public let isWarmup: Bool

    public init(weightKg: Double, reps: Int, isWarmup: Bool = false) {
        self.weightKg = weightKg
        self.reps = reps
        self.isWarmup = isWarmup
    }
}

/// One exercise's sets within a session, tagged with a primary muscle group.
public struct FixtureExercise: Sendable, Equatable {
    public let title: String
    public let muscle: String
    public let sets: [FixtureSet]

    public init(title: String, muscle: String, sets: [FixtureSet]) {
        self.title = title
        self.muscle = muscle
        self.sets = sets
    }
}

/// One workout session: a title, a start/end time, and the exercises logged.
public struct FixtureSession: Sendable, Equatable {
    public let title: String
    public let start: CivilDateTime
    public let durationMinutes: Int
    public let exercises: [FixtureExercise]

    public init(title: String, start: CivilDateTime, durationMinutes: Int, exercises: [FixtureExercise]) {
        self.title = title
        self.start = start
        self.durationMinutes = durationMinutes
        self.exercises = exercises
    }

    public var end: CivilDateTime {
        CivilDateTime(dayCount: start.dayCount, minuteOfDay: start.minuteOfDay + durationMinutes)
    }
}

/// Opt-in knobs for `WorkoutHistoryGenerator.generate`. Every probability is
/// in `[0, 1]` and defaults to `0`/`false`, so `HistoryGenerationOptions()`
/// (equivalently `.none`) reproduces the generator's original, simpler
/// output exactly — these are additive, not a behavior change for existing
/// callers.
public struct HistoryGenerationOptions: Sendable {
    /// Probability a non-bodyweight exercise's working sets are preceded by
    /// one lighter warmup set (`FixtureSet.isWarmup == true`).
    public var warmupSetProbability: Double
    /// When `true`, one non-bodyweight exercise from the pool is designated
    /// "recurring": whenever it's chosen for a session, its weight is
    /// interpolated from light to heavy across the requested span instead of
    /// drawn uniformly at random, simulating gradual progressive overload.
    public var progressiveOverloadEnabled: Bool
    /// Probability any individual set records 0 reps — an attempted-but-
    /// failed set — independent of warmup/working status.
    public var failedSetProbability: Double
    /// Probability a whole session is logged with zero exercises.
    public var emptySessionProbability: Double
    /// Probability one of a session's (non-bodyweight) exercises is logged a
    /// second time later in the same session at a different weight: two
    /// distinct `FixtureExercise` entries sharing a title, not sets within a
    /// single entry — Burly v1 does not model supersets or dropsets.
    public var repeatedExerciseProbability: Double

    public init(
        warmupSetProbability: Double = 0,
        progressiveOverloadEnabled: Bool = false,
        failedSetProbability: Double = 0,
        emptySessionProbability: Double = 0,
        repeatedExerciseProbability: Double = 0
    ) {
        self.warmupSetProbability = warmupSetProbability
        self.progressiveOverloadEnabled = progressiveOverloadEnabled
        self.failedSetProbability = failedSetProbability
        self.emptySessionProbability = emptySessionProbability
        self.repeatedExerciseProbability = repeatedExerciseProbability
    }

    /// All knobs off — the generator's original, unconditional behavior.
    public static let none = HistoryGenerationOptions()
}

/// Generates deterministic synthetic workout histories.
public enum WorkoutHistoryGenerator {
    /// (exercise title, primary muscle, plausible bodyweight-only flag)
    private static let exercisePool: [(title: String, muscle: String, bodyweightOnly: Bool)] = [
        ("Barbell Back Squat", "Quadriceps", false),
        ("Barbell Bench Press", "Chest", false),
        ("Conventional Deadlift", "Hamstrings", false),
        ("Overhead Press", "Shoulders", false),
        ("Barbell Row", "Back", false),
        ("Pull-Up", "Back", true),
        ("Dip", "Triceps", true),
        ("Dumbbell Curl", "Biceps", false),
        ("Leg Press", "Quadriceps", false),
        ("Hanging Leg Raise", "Abs", true),
        ("Lat Pulldown", "Back", false),
        ("Walking Lunge", "Quadriceps", false)
    ]

    private static let sessionTitles = [
        "Push Day", "Pull Day", "Leg Day", "Upper Body", "Lower Body", "Full Body"
    ]

    /// Probability the designated "recurring" exercise (see
    /// `HistoryGenerationOptions.progressiveOverloadEnabled`) is included in
    /// any given session, once one is designated.
    private static let progressiveInclusionProbability = 0.7

    /// Generates `sessionCount` sessions with start dates spread across the
    /// `spanDays` days up to and including `startDate`, deterministically
    /// derived from `seed`.
    ///
    /// - Parameters:
    ///   - seed: Drives every random choice; the same seed always yields the
    ///     same sessions (see `SeededGenerator`).
    ///   - sessionCount: Number of sessions to produce, must be >= 0.
    ///   - spanDays: Width of the date range sessions are scattered across.
    ///   - startDate: The most recent day a session can land on. Callers
    ///     pick a plausible modern date (e.g. "today"); the generator no
    ///     longer assumes day-count `0` means "today" internally, since the
    ///     CSV formatter renders day-count `0` literally as the 1970-01-01
    ///     epoch — that mismatch used to produce 1969/1970-dated "recent"
    ///     exports. Output is deterministic given `(seed, startDate)` (and
    ///     the other parameters).
    ///   - options: Opt-in knobs for warmups, progressive overload, failed
    ///     sets, empty sessions, and repeated exercises. Defaults to
    ///     `.none`, reproducing the original deterministic shape exactly.
    /// - Returns: Sessions sorted oldest-to-newest.
    public static func generate(
        seed: UInt64,
        sessionCount: Int,
        spanDays: Int,
        startDate: CivilDate,
        options: HistoryGenerationOptions = .none
    ) -> [FixtureSession] {
        guard sessionCount > 0, spanDays > 0 else { return [] }
        var rng = SeededGenerator(seed: seed)

        let nonBodyweightIndices = exercisePool.indices.filter { !exercisePool[$0].bodyweightOnly }
        let progressiveIndex: Int? = (options.progressiveOverloadEnabled && !nonBodyweightIndices.isEmpty)
            ? nonBodyweightIndices[Int.random(in: 0..<nonBodyweightIndices.count, using: &rng)]
            : nil

        var sessions: [FixtureSession] = []
        sessions.reserveCapacity(sessionCount)

        for _ in 0..<sessionCount {
            let dayOffset = Int.random(in: 0...(spanDays), using: &rng)
            let dayCount = startDate.dayCount - spanDays + dayOffset // oldest = startDate - spanDays, newest = startDate
            let startMinute = Int.random(in: (6 * 60)...(20 * 60), using: &rng) // 06:00-20:00
            let title = sessionTitles[Int.random(in: 0..<sessionTitles.count, using: &rng)]

            let isEmptySession = options.emptySessionProbability > 0
                && Double.random(in: 0..<1, using: &rng) < options.emptySessionProbability

            var exercises: [FixtureExercise] = []
            if !isEmptySession {
                let exerciseCount = Int.random(in: 3...5, using: &rng)
                var usedIndices = Set<Int>()

                if let progressiveIndex,
                   Double.random(in: 0..<1, using: &rng) < progressiveInclusionProbability {
                    let recencyFraction = Double(dayOffset) / Double(spanDays)
                    let pick = exercisePool[progressiveIndex]
                    let weight = progressiveWeight(fraction: recencyFraction, rng: &rng)
                    usedIndices.insert(progressiveIndex)
                    exercises.append(makeExercise(pick, baseWeight: weight, options: options, rng: &rng))
                }

                while exercises.count < exerciseCount {
                    let idx = Int.random(in: 0..<exercisePool.count, using: &rng)
                    guard !usedIndices.contains(idx) else { continue }
                    usedIndices.insert(idx)
                    let pick = exercisePool[idx]

                    let baseWeight: Double = pick.bodyweightOnly
                        ? 0
                        : Double(Int.random(in: 8...60, using: &rng) * 5) // 40-300 in 5kg steps
                    exercises.append(makeExercise(pick, baseWeight: baseWeight, options: options, rng: &rng))
                }

                if options.repeatedExerciseProbability > 0,
                   Double.random(in: 0..<1, using: &rng) < options.repeatedExerciseProbability {
                    let weightedExercises = exercises.filter { ($0.sets.last?.weightKg ?? 0) > 0 }
                    if !weightedExercises.isEmpty {
                        let source = weightedExercises[Int.random(in: 0..<weightedExercises.count, using: &rng)]
                        let originalWeight = source.sets.last?.weightKg ?? 0
                        let delta = Double(Int.random(in: 1...8, using: &rng) * 5) // 5-40kg, 5kg steps
                        let newWeight = Bool.random(using: &rng)
                            ? originalWeight + delta
                            : max(5, originalWeight - delta) // always < originalWeight (>= 40), so always different
                        exercises.append(makeExercise(
                            (title: source.title, muscle: source.muscle, bodyweightOnly: false),
                            baseWeight: newWeight,
                            options: options,
                            rng: &rng
                        ))
                    }
                }
            }

            let durationMinutes = Int.random(in: 30...75, using: &rng)
            sessions.append(FixtureSession(
                title: title,
                start: CivilDateTime(dayCount: dayCount, minuteOfDay: startMinute),
                durationMinutes: durationMinutes,
                exercises: exercises
            ))
        }

        return sessions.sorted { $0.start < $1.start }
    }

    /// Interpolates a plausible progressive-overload weight for `fraction`
    /// (0 = oldest end of the span, 1 = newest), from a light starting load
    /// up to a heavier one, with a small amount of session-to-session jitter
    /// so it trends upward without being perfectly linear.
    private static func progressiveWeight(fraction: Double, rng: inout SeededGenerator) -> Double {
        let minWeight = 40.0
        let maxWeight = 140.0
        let jitter = Double(Int.random(in: -1...1, using: &rng) * 5) // -5, 0, or 5 kg
        let raw = minWeight + fraction * (maxWeight - minWeight) + jitter
        return max(0, (raw / 5).rounded() * 5)
    }

    /// Builds one exercise's sets: an optional warmup set (per
    /// `options.warmupSetProbability`), followed by 3-4 working sets at
    /// `baseWeight`, each optionally zeroed out to a failed set (per
    /// `options.failedSetProbability`).
    private static func makeExercise(
        _ pick: (title: String, muscle: String, bodyweightOnly: Bool),
        baseWeight: Double,
        options: HistoryGenerationOptions,
        rng: inout SeededGenerator
    ) -> FixtureExercise {
        let setCount = Int.random(in: 3...4, using: &rng)
        var sets: [FixtureSet] = []
        sets.reserveCapacity(setCount + 1)

        if !pick.bodyweightOnly, baseWeight > 0, options.warmupSetProbability > 0,
           Double.random(in: 0..<1, using: &rng) < options.warmupSetProbability {
            let warmupWeight = ((baseWeight * 0.6) / 5).rounded() * 5
            let warmupReps = Int.random(in: 5...8, using: &rng)
            sets.append(FixtureSet(weightKg: warmupWeight, reps: warmupReps, isWarmup: true))
        }

        for _ in 0..<setCount {
            var reps = Int.random(in: 5...12, using: &rng)
            if options.failedSetProbability > 0,
               Double.random(in: 0..<1, using: &rng) < options.failedSetProbability {
                reps = 0
            }
            sets.append(FixtureSet(weightKg: baseWeight, reps: reps))
        }

        return FixtureExercise(title: pick.title, muscle: pick.muscle, sets: sets)
    }
}
