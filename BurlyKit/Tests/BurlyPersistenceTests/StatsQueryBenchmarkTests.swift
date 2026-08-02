// SPDX-License-Identifier: GPL-3.0-or-later
// m6-01 — the 50k-SetRecord benchmark the task brief requires: wall time
// and peak memory for the §7 stats queries (`loggedSetSlices`,
// `loggedSessionDates`) against a store at roughly the top of the
// architecture doc's stated realistic scale ("~40-50k rows for a decade of
// lifting").
//
// Gated behind an environment variable, mirroring `MigrationSpikeTests`
// (see that file's header for why an opt-in gate rather than always-on):
// seeding ~50k SetRecords through ~3,000 individual `createSession` saves
// takes real wall-clock time (tens of seconds), which does not belong in
// the default `swift test` loop every contributor runs on every change.
//
//     swift test                                                # skipped
//     BURLY_RUN_STATS_BENCHMARK=1 swift test \
//         --filter StatsQueryBenchmarkTests                     # runs it
//
// This is NOT the device-floor check. It measures on whatever Mac runs it
// and prints the numbers; task m8-02 owns verifying those numbers hold on
// the iPhone 12 Pro floor. The point of this file is that the benchmark
// *exists* and is runnable, not that a Mac timing is an acceptance gate.
import Foundation
import Darwin
import Testing
import BurlyCore
import BurlyFixtures
@testable import BurlyPersistence

let statsBenchmarkIsEnabled =
    ProcessInfo.processInfo.environment["BURLY_RUN_STATS_BENCHMARK"] == "1"

@Suite(
    "m6-01 — 50k-SetRecord stats query benchmark",
    .enabled(
        if: statsBenchmarkIsEnabled,
        "set BURLY_RUN_STATS_BENCHMARK=1 to run this — it seeds ~50k SetRecords first and is too slow for the default `swift test` loop"
    ),
    .serialized
)
struct StatsQueryBenchmarkTests {

    @Test("loggedSetSlices / loggedSessionDates: wall time + peak RSS at ~50k SetRecords")
    func benchmarkStatsQueriesAtScale() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let seed = try BenchmarkFixture.seedStore(at: url)
        print("""

        [m6-01 stats benchmark] seeded \(seed.sessionCount) sessions / \(seed.setCount) SetRecords \
        across \(seed.exerciseCount) exercises in \(String(format: "%.2f", seed.seedDuration))s \
        (peak RSS after seeding: \(formatBytes(seed.peakResidentBytesAfterSeeding)))
        """)

        // A fresh store on the same file — a new `ModelContext`, so the
        // measured queries pay real fetch/fault cost instead of reusing
        // the seeding context's identity-map cache. This is the "app
        // launches, opens a chart" shape, not "same session queries what
        // it just wrote".
        let store = try SwiftDataStore(kind: .phone, at: .file(url))

        // (a) A realistic trailing-window query — the shape every §7 range
        // except the PR chart's "all" actually uses. Bounded by date, so
        // this should touch a small fraction of the 50k rows regardless of
        // total history size.
        let trailingWindowStart = seed.newestSessionDate.addingTimeInterval(-90 * 24 * 60 * 60)
        let (trailingSlices, trailingTime, trailingPeak) = try measure {
            try store.loggedSetSlices(exerciseID: nil, since: trailingWindowStart, through: nil)
        }
        print("[m6-01 stats benchmark] loggedSetSlices(all exercises, trailing 90d): \(trailingSlices.count) slices in \(String(format: "%.4f", trailingTime))s, peak RSS \(formatBytes(trailingPeak))")
        #expect(trailingSlices.isEmpty == false)

        // (b) The worst case this API allows: one exercise, `since: nil` —
        // the PR chart's "all" range. `since`/`through` are both nil, so
        // this fetches every SetRecord row once (bounded by the store's
        // total size, not multiplied by relationship fault amplification —
        // see BurlyStore's stats-query doc) and filters to one exercise in
        // Swift afterward.
        let (allTimeSlices, allTimeQueryTime, allTimePeak) = try measure {
            try store.loggedSetSlices(exerciseID: seed.benchExerciseID, since: nil, through: nil)
        }
        print("[m6-01 stats benchmark] loggedSetSlices(one exercise, all-time): \(allTimeSlices.count) slices in \(String(format: "%.4f", allTimeQueryTime))s, peak RSS \(formatBytes(allTimePeak))")
        #expect(allTimeSlices.isEmpty == false)
        #expect(allTimeSlices.allSatisfy { $0.exerciseID == seed.benchExerciseID })

        // (c) Session-level dates only, all-time — bounded by session
        // count (~3k), not set count (~50k), since this never touches
        // `.items`.
        let (dates, datesTime, datesPeak) = try measure {
            try store.loggedSessionDates(since: nil, through: nil)
        }
        print("[m6-01 stats benchmark] loggedSessionDates(all-time): \(dates.count) dates in \(String(format: "%.4f", datesTime))s, peak RSS \(formatBytes(datesPeak))")
        #expect(dates.count == seed.sessionCount)

        print("[m6-01 stats benchmark] done\n")
    }
}

// MARK: - Measurement helpers

/// Wall time and the process's peak resident set size *as of right after*
/// `body` returns. `resident_size_max` (below) is a running high-water mark
/// since process start, not a per-call delta, so this is "the peak so far",
/// not "the peak this call alone caused" — reported alongside the running
/// baseline each call site prints so the delta is still readable.
private func measure<T>(_ body: () throws -> T) rethrows -> (result: T, seconds: Double, peakResidentBytes: UInt64) {
    let start = Date()
    let result = try body()
    let elapsed = Date().timeIntervalSince(start)
    return (result, elapsed, currentPeakResidentBytes())
}

/// `mach_task_basic_info.resident_size_max` — Darwin's own peak-RSS
/// counter for the current process, no Instruments required. Returns 0 if
/// the `task_info` call fails (never observed locally; failing the
/// benchmark over an unreadable memory counter would be the wrong kind of
/// flaky).
private func currentPeakResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size_max)
}

private func formatBytes(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

// MARK: - Seeding

private enum BenchmarkFixture {
    struct SeedResult {
        let sessionCount: Int
        let setCount: Int
        let exerciseCount: Int
        let benchExerciseID: UUID
        let newestSessionDate: Date
        let seedDuration: Double
        let peakResidentBytesAfterSeeding: UInt64
    }

    /// One tag per synthetic exercise title — approximate on purpose. This
    /// benchmark measures query wall time and memory at scale; it does not
    /// assert on muscle-split numbers (that's `MuscleSplitStatsTests`,
    /// fixture-truth tested against hand-built data), so a plausible tag is
    /// all this needs.
    private static let muscleGroupsByTitle: [String: [MuscleGroup]] = [
        "Barbell Back Squat": [.quads, .glutes],
        "Barbell Bench Press": [.chest, .triceps],
        "Conventional Deadlift": [.hamstrings, .glutes],
        "Overhead Press": [.shoulders, .triceps],
        "Barbell Row": [.upperBack, .lats],
        "Pull-Up": [.lats, .biceps],
        "Dip": [.triceps, .chest],
        "Dumbbell Curl": [.biceps],
        "Leg Press": [.quads],
        "Hanging Leg Raise": [.core],
        "Lat Pulldown": [.lats],
        "Walking Lunge": [.quads, .glutes]
    ]

    /// Generates a deterministic synthetic history via
    /// `WorkoutHistoryGenerator` and writes it into a fresh file-backed
    /// store, one `createSession` per generated session (the same write
    /// path a real Hevy import or years of live workouts would use — no
    /// shortcut through `BurlyPersistence`'s internals).
    static func seedStore(at url: URL) throws -> SeedResult {
        let start = Date()

        // ~3,600 sessions × ~14 sets/session (3-5 exercises × 3-4 sets) is
        // comfortably north of the 50k-SetRecord target the task brief
        // names; the exact count is reported, not asserted to the row.
        let sessions = WorkoutHistoryGenerator.generate(
            seed: 0xB0_5E_ED_01,
            sessionCount: 3_600,
            spanDays: 10 * 365,
            startDate: CivilDate(year: 2026, month: 8, day: 1)
        )

        let store = try SwiftDataStore(kind: .phone, at: .file(url))

        var exerciseIDByTitle: [String: UUID] = [:]
        var setCount = 0
        var newestSessionDate = Date.distantPast

        for session in sessions {
            var items: [SessionItemData] = []
            for exercise in session.exercises {
                let exerciseID: UUID
                if let existing = exerciseIDByTitle[exercise.title] {
                    exerciseID = existing
                } else {
                    let id = UUID()
                    try store.createExercise(
                        ExerciseData(
                            id: id,
                            name: exercise.title,
                            muscleGroups: muscleGroupsByTitle[exercise.title] ?? [.core],
                            origin: .curated
                        )
                    )
                    exerciseIDByTitle[exercise.title] = id
                    exerciseID = id
                }

                let sessionStart = date(from: session.start)
                let sets = exercise.sets.enumerated().map { index, set in
                    SetRecordData(
                        order: index,
                        weight: Weight(kg: set.weightKg),
                        reps: set.reps,
                        isWarmup: set.isWarmup,
                        completedAt: sessionStart
                    )
                }
                setCount += sets.count
                items.append(SessionItemData(exerciseID: exerciseID, order: items.count, sets: sets))
            }

            let startedAt = date(from: session.start)
            newestSessionDate = max(newestSessionDate, startedAt)
            try store.createSession(
                SessionData(
                    startedAt: startedAt,
                    endedAt: date(from: session.end),
                    state: .logged,
                    origin: .live,
                    items: items
                )
            )
        }

        return SeedResult(
            sessionCount: sessions.count,
            setCount: setCount,
            exerciseCount: exerciseIDByTitle.count,
            // "Barbell Bench Press" is in the generator's pool unconditionally
            // and used across most sessions — a representative single-
            // exercise query target for the all-time PR-chart benchmark.
            benchExerciseID: try #require(exerciseIDByTitle["Barbell Bench Press"]),
            newestSessionDate: newestSessionDate,
            seedDuration: Date().timeIntervalSince(start),
            peakResidentBytesAfterSeeding: currentPeakResidentBytes()
        )
    }

    /// `CivilDateTime` (days since epoch + minute-of-day, no timezone) to a
    /// `Date`, the same "no timezone concept" interpretation
    /// `HevyCSVGenerator` already formats these values under.
    private static func date(from civil: CivilDateTime) -> Date {
        Date(timeIntervalSince1970: Double(civil.dayCount) * 86_400 + Double(civil.minuteOfDay) * 60)
    }
}
