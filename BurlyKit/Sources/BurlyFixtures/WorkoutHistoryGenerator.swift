// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// Synthetic workout-history generator. Produces plausible-looking lifting
// sessions for use as test/preview data. All output is synthetic: exercise
// names come from a fixed built-in list, no real person's training history,
// body metrics, or identity is used or referenced anywhere in this module.
//
// Pure Swift, zero framework imports.

/// A single logged set: `weightKg` of 0 is the project-wide convention for a
/// bodyweight set (e.g. pull-ups, dips) rather than an external load.
public struct FixtureSet: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
}

/// One exercise's sets within a session, tagged with a primary muscle group.
public struct FixtureExercise: Sendable, Equatable {
    public let title: String
    public let muscle: String
    public let sets: [FixtureSet]
}

/// One workout session: a title, a start/end time, and the exercises logged.
public struct FixtureSession: Sendable, Equatable {
    public let title: String
    public let start: CivilDateTime
    public let durationMinutes: Int
    public let exercises: [FixtureExercise]

    public var end: CivilDateTime {
        CivilDateTime(dayCount: start.dayCount, minuteOfDay: start.minuteOfDay + durationMinutes)
    }
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

    /// Generates `sessionCount` sessions with start dates spread across the
    /// most recent `spanDays` days (ending "today", represented as
    /// `dayCount == 0` — callers map this onto real dates as needed),
    /// deterministically derived from `seed`.
    ///
    /// - Parameters:
    ///   - seed: Drives every random choice; the same seed always yields the
    ///     same sessions (see `SeededGenerator`).
    ///   - sessionCount: Number of sessions to produce, must be >= 0.
    ///   - spanDays: Width of the date range sessions are scattered across.
    /// - Returns: Sessions sorted oldest-to-newest.
    public static func generate(seed: UInt64, sessionCount: Int, spanDays: Int) -> [FixtureSession] {
        guard sessionCount > 0, spanDays > 0 else { return [] }
        var rng = SeededGenerator(seed: seed)

        var sessions: [FixtureSession] = []
        sessions.reserveCapacity(sessionCount)

        for _ in 0..<sessionCount {
            let dayOffset = Int.random(in: 0...(spanDays), using: &rng)
            let dayCount = -spanDays + dayOffset // oldest = -spanDays, newest = 0
            let startMinute = Int.random(in: (6 * 60)...(20 * 60), using: &rng) // 06:00-20:00
            let title = sessionTitles[Int.random(in: 0..<sessionTitles.count, using: &rng)]

            let exerciseCount = Int.random(in: 3...5, using: &rng)
            var exercises: [FixtureExercise] = []
            exercises.reserveCapacity(exerciseCount)
            var usedIndices = Set<Int>()
            while exercises.count < exerciseCount {
                let idx = Int.random(in: 0..<exercisePool.count, using: &rng)
                guard !usedIndices.contains(idx) else { continue }
                usedIndices.insert(idx)
                let pick = exercisePool[idx]

                let setCount = Int.random(in: 3...4, using: &rng)
                var sets: [FixtureSet] = []
                sets.reserveCapacity(setCount)
                let baseWeight: Double = pick.bodyweightOnly
                    ? 0
                    : Double(Int.random(in: 8...60, using: &rng) * 5) // 40-300 in 5kg steps
                for _ in 0..<setCount {
                    let reps = Int.random(in: 5...12, using: &rng)
                    sets.append(FixtureSet(weightKg: baseWeight, reps: reps))
                }
                exercises.append(FixtureExercise(title: pick.title, muscle: pick.muscle, sets: sets))
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
}
