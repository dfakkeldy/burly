// SPDX-License-Identifier: MIT
// m4-04 review round 1, major 10 — a gated 50k-SetRecord benchmark for
// `SessionDigestGenerator.generate`, mirroring
// `BurlyPersistenceTests.StatsQueryBenchmarkTests`'s pattern exactly:
// deterministic seeding via `WorkoutHistoryGenerator`, wall time + Darwin
// process high-water RSS via `mach_task_basic_info`, gated behind an
// environment variable so the ~tens-of-seconds seed cost never lands in the
// default `swift test` loop.
//
//     swift test                                                  # skipped
//     BURLY_RUN_DIGEST_BENCHMARK=1 swift test \
//         --filter DigestGenerationBenchmarkTests                 # runs it
//
// Why this benchmark exists (the review's own words): `SessionDigestGenerator
// .generate` used to read `BurlyStore.allLoggedSetSlices()` — the FULL
// current `.logged` history, every time — and group every slice. That was
// linear in total `SetRecord` count with no windowing, unlike every §7
// stats query `StatsQueryBenchmarkTests` already covers, and it crossed the
// threshold below (6.1-8.4 s on hosted CI; issue #24). It now reads only
// each exercise's latest session (`latestLoggedSetSlices(forExercises:)`),
// and this benchmark also checks that answer against the full-history
// derivation at the same scale. This file's job is to put a number on the
// cost at the architecture doc's stated realistic ceiling (~40-50k rows for
// a decade of lifting) and flag it loudly if it crosses the review's named
// thresholds (~3s wall, ~250MB high-water RSS). A regression here is a
// ticket to m8-02 (the device-floor task), not a silent pass.
import Foundation
import Darwin
import CryptoKit
import Testing
import BurlyCore
import BurlyPersistence
import BurlyFixtures
import BurlySync
@testable import BurlyPhoneSync

let digestBenchmarkIsEnabled =
    ProcessInfo.processInfo.environment["BURLY_RUN_DIGEST_BENCHMARK"] == "1"

/// Keep the original three-second and RSS thresholds. The explicitly gated
/// benchmark also fails when the median of five cold-context generations
/// crosses the wall-time threshold. RSS is a process-lifetime high-water
/// mark, so it remains a diagnostic rather than an interval allocation test.
private let wallTimeThresholdSeconds = 3.0
private let residentBytesThreshold: UInt64 = 250 * 1_048_576

@MainActor
@Suite(
    "m4-04 review round 1, major 10 — SessionDigestGenerator 50k-SetRecord benchmark",
    .enabled(
        if: digestBenchmarkIsEnabled,
        "set BURLY_RUN_DIGEST_BENCHMARK=1 to run this — it seeds ~50k SetRecords first and is too slow for the default `swift test` loop"
    ),
    .serialized
)
struct DigestGenerationBenchmarkTests {

    @Test("SessionDigestGenerator.generate: wall time + process high-water RSS at ~50k SetRecords")
    func benchmarkDigestGenerationAtScale() throws {
        let url = try makeDigestBenchmarkStoreURL()
        defer { removeDigestBenchmarkStoreFiles(at: url) }

        let seed = try DigestBenchmarkFixture.seedStore(at: url)
        print("""

        [m4-04 digest benchmark] seeded \(seed.sessionCount) sessions / \(seed.setCount) SetRecords \
        across \(seed.exerciseCount) exercises in \(String(format: "%.2f", seed.seedDuration))s \
        (process high-water RSS after seeding: \(formatDigestBenchmarkBytes(seed.peakResidentBytesAfterSeeding)))
        """)

        // A fresh store on the same file — a new `ModelContext`, so the
        // measured generation pays real fetch/fault cost rather than
        // reusing the seeding context's identity-map cache. Same rationale
        // as `StatsQueryBenchmarkTests`: "app launches, publishes a digest,"
        // not "same session digests what it just wrote."
        let acked: Set<UUID> = [
            UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!,
            UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!
        ]
        var timings: [Double] = []
        var payloads: [BurlyDigestPayloadDTO] = []
        for run in 1...5 {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            let (payload, seconds, _) = try measureDigestBenchmark {
                try SessionDigestGenerator.generate(from: store, snapshotVersion: 42, ackedSessionIDs: acked)
            }
            timings.append(seconds)
            payloads.append(payload)
            print("[digest five runs] run \(run): \(seconds)s")
        }
        let payload = try #require(payloads.first)
        let seconds = timings.sorted()[2]
        let peakBytes = currentDigestBenchmarkPeakResidentBytes()
        print("[digest five runs] median: \(seconds)s")
        #expect(seconds < wallTimeThresholdSeconds, "digest generation median must stay below 3 seconds")

        print("""
        [m4-04 digest benchmark] generate(): \(payload.lastPerformance.count) exercise entries, \
        \(String(format: "%.4f", seconds))s, process high-water RSS \(formatDigestBenchmarkBytes(peakBytes))
        """)

        #expect(payload.lastPerformance.count == seed.exerciseCount)
        #expect(payload.snapshotVersion == 42)
        #expect(Set(payload.ackedSessionIDs) == acked)

        // Issue #24: generate() now reads only each exercise's latest
        // session. Hold it to the full-history derivation it replaced, at
        // this scale, in another fresh context (after the timed call, so
        // the timing above never benefits from this read's cache).
        let referenceStore = try SwiftDataStore(kind: .phone, at: .file(url))
        let (allSlices, fetchSeconds, _) = try measureDigestBenchmark {
            try referenceStore.allLoggedSetSlices()
        }
        let (fullHistory, computeSeconds, _) = measureDigestBenchmark {
            SessionDigestGenerator.latestPerformancePerExercise(from: allSlices)
        }
        let fullSeconds = fetchSeconds + computeSeconds
        print("[digest phases] full-history fetch \(fetchSeconds)s; pure derivation \(computeSeconds)s")
        #expect(payload.lastPerformance == fullHistory)
        // Compare the complete encoded envelope against the full-history
        // oracle on the fixed-seed persisted fixture. Sort JSON object keys
        // because Foundation does not promise their default ordering.
        let reference = BurlyDigestPayloadDTO(
            snapshotVersion: 42,
            lastPerformance: fullHistory,
            ackedSessionIDs: acked.sorted { $0.uuidString < $1.uuidString },
            routineLastPerformed: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedBytes = try BurlySyncEnvelope(payload: .digest(reference)).encodedData(using: encoder)
        let hash = SHA256.hash(data: expectedBytes).map { String(format: "%02x", $0) }.joined()
        // Captured on origin/main a6bef0b before this test-only change.
        #expect(hash == "069caa3a3a01092a58b8f6be3f0c34f422b2da3b47730708f695cc71e40922f6")
        print("[digest bytes] fixed-seed envelope SHA256 \(hash), \(expectedBytes.count) bytes")
        for generated in payloads {
            let bytes = try BurlySyncEnvelope(payload: .digest(generated)).encodedData(using: encoder)
            #expect(bytes == expectedBytes)
        }
        print("""
        [m4-04 digest benchmark] full-history derivation for comparison: \(fullHistory.count) entries, \
        \(String(format: "%.4f", fullSeconds))s
        """)

        if seconds > wallTimeThresholdSeconds {
            print("""
            \n\
            ⚠️⚠️⚠️ [m4-04 digest benchmark] WALL TIME REGRESSION: \(String(format: "%.4f", seconds))s \
            exceeds the ~\(String(format: "%.0f", wallTimeThresholdSeconds))s threshold at ~50k SetRecords. \
            SessionDigestGenerator.generate reads every session item to pick each exercise's latest \
            session (see that file's header doc) — this is a real cost-at-scale signal, not a flaky benchmark. \
            File/confirm a ticket against m8-02 (device-floor verification) rather than silently \
            accepting this regression. ⚠️⚠️⚠️\n
            """)
        }
        if peakBytes > residentBytesThreshold {
            print("""
            \n\
            ⚠️⚠️⚠️ [m4-04 digest benchmark] MEMORY REGRESSION: process high-water RSS \
            \(formatDigestBenchmarkBytes(peakBytes)) exceeds the ~\(formatDigestBenchmarkBytes(residentBytesThreshold)) \
            threshold at ~50k SetRecords. File/confirm a ticket against m8-02 rather than silently \
            accepting this regression. ⚠️⚠️⚠️\n
            """)
        }

        print("[m4-04 digest benchmark] done\n")
    }
}

// Byte equivalence also runs in the ordinary unit suite, without the
// expensive 50k-row benchmark gate.
@MainActor
@Suite("#24 — fixed-seed digest wire equivalence")
struct DigestWireEquivalenceTests {
    @Test("cold-store digest bytes equal the full-history reference on a fixed seed")
    func fixedSeedWireBytes() throws {
        let url = try makeDigestBenchmarkStoreURL()
        defer { removeDigestBenchmarkStoreFiles(at: url) }
        _ = try DigestBenchmarkFixture.seedStore(at: url, sessionCount: 36)
        let acked: Set<UUID> = [UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!]
        let referenceStore = try SwiftDataStore(kind: .phone, at: .file(url))
        let reference = BurlyDigestPayloadDTO(
            snapshotVersion: 42,
            lastPerformance: SessionDigestGenerator.latestPerformancePerExercise(
                from: try referenceStore.allLoggedSetSlices()
            ),
            ackedSessionIDs: acked.sorted { $0.uuidString < $1.uuidString },
            routineLastPerformed: []
        )
        let cold = try SwiftDataStore(kind: .phone, at: .file(url))
        let generated = try SessionDigestGenerator.generate(
            from: cold, snapshotVersion: 42, ackedSessionIDs: acked
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try BurlySyncEnvelope(payload: .digest(generated)).encodedData(using: encoder)
            == BurlySyncEnvelope(payload: .digest(reference)).encodedData(using: encoder))
    }
}

// MARK: - Measurement helpers
//
// Deliberately duplicated from `StatsQueryBenchmarkTests` rather than
// shared: that file's helpers are `private` to their own file/target
// (`BurlyPersistenceTests`, not `BurlyPhoneSyncTests`), and promoting them to
// a shared test-support module for two one-file benchmarks is not a
// refactor this task's scope calls for. Same "process high-water RSS, not
// this call's own peak" caveat applies — see that file's doc for the full
// explanation of why Darwin's counter is a running maximum since process
// start, not an interval measurement.

private func measureDigestBenchmark<T>(_ body: () throws -> T) rethrows -> (result: T, seconds: Double, peakResidentBytes: UInt64) {
    let start = Date()
    let result = try body()
    let elapsed = Date().timeIntervalSince(start)
    return (result, elapsed, currentDigestBenchmarkPeakResidentBytes())
}

private func currentDigestBenchmarkPeakResidentBytes() -> UInt64 {
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

private func formatDigestBenchmarkBytes(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

// MARK: - Temp store file helpers
//
// `BurlyPersistenceTests.StoreTestSupport`'s `makeTemporaryStoreURL`/
// `removeStoreFiles` are `internal` to that target, not visible from
// `BurlyPhoneSyncTests` — separate Swift modules, not merely separate
// files — so this is a small local duplicate rather than a cross-target
// dependency for two functions.
private func makeDigestBenchmarkStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "burly-digest-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "Burly.store", directoryHint: .notDirectory)
}

private func removeDigestBenchmarkStoreFiles(at url: URL) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Seeding

@MainActor
private enum DigestBenchmarkFixture {
    struct SeedResult {
        let sessionCount: Int
        let setCount: Int
        let exerciseCount: Int
        let seedDuration: Double
        let peakResidentBytesAfterSeeding: UInt64
    }

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

    /// Same generator, seed, and target row count as
    /// `StatsQueryBenchmarkTests.BenchmarkFixture.seedStore` — ~3,600
    /// sessions comfortably north of the 50k-SetRecord target — so the two
    /// benchmarks' numbers are directly comparable at a glance.
    static func seedStore(at url: URL, sessionCount: Int = 3_600) throws -> SeedResult {
        let start = Date()

        let sessions = WorkoutHistoryGenerator.generate(
            seed: 0xB0_5E_ED_01,
            sessionCount: sessionCount,
            spanDays: 10 * 365,
            startDate: CivilDate(year: 2026, month: 8, day: 1)
        )

        let store = try SwiftDataStore(kind: .phone, at: .file(url))

        var exerciseIDByTitle: [String: UUID] = [:]
        var setCount = 0
        // Stable identities make the complete wire bytes reproducible,
        // including session/set UUID tie breakers.
        var identity: UInt64 = 0
        func nextID() -> UUID {
            identity += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", identity))!
        }

        for session in sessions {
            var items: [SessionItemData] = []
            for exercise in session.exercises {
                let exerciseID: UUID
                if let existing = exerciseIDByTitle[exercise.title] {
                    exerciseID = existing
                } else {
                    let id = nextID()
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
                        id: nextID(),
                        order: index,
                        weight: Weight(kg: set.weightKg),
                        reps: set.reps,
                        isWarmup: set.isWarmup,
                        completedAt: sessionStart
                    )
                }
                setCount += sets.count
                items.append(SessionItemData(id: nextID(), exerciseID: exerciseID, order: items.count, sets: sets))
            }

            try store.createSession(
                SessionData(
                    id: nextID(),
                    startedAt: date(from: session.start),
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
            seedDuration: Date().timeIntervalSince(start),
            peakResidentBytesAfterSeeding: currentDigestBenchmarkPeakResidentBytes()
        )
    }

    private static func date(from civil: CivilDateTime) -> Date {
        Date(timeIntervalSince1970: Double(civil.dayCount) * 86_400 + Double(civil.minuteOfDay) * 60)
    }
}
