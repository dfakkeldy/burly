// SPDX-License-Identifier: GPL-3.0-or-later
// Test support for the §2/§3 session-engine suites: a hand-driven clock, a
// deterministic id source, a seeded RNG, and routine fixtures.
//
// BurlyFixtures is not a dependency of this test target (Package.swift is
// owned by a concurrent task and is not touched here), so the generator
// below is local and deliberately tiny: SplitMix64 over a fixed seed, which
// is all the property-style mutation tests need to be reproducible.
import Foundation
@testable import BurlyCore

// MARK: - Clock

/// A `WallClock` the test moves by hand. `@unchecked Sendable`: the tests
/// that share one are single-threaded, and the whole point is a mutable
/// instant.
final class ManualClock: WallClock, @unchecked Sendable {
    private var instant: Date

    init(_ instant: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.instant = instant
    }

    var now: Date { instant }

    /// Moves the clock forward — including by hours, to stand in for a
    /// process suspension or a relaunch (§3).
    func advance(_ seconds: TimeInterval) {
        instant = instant.addingTimeInterval(seconds)
    }

    func set(_ newInstant: Date) {
        instant = newInstant
    }
}

// MARK: - Identity

/// Deterministic, ordered UUIDs so failures are readable and reproducible.
final class SequentialIDs: @unchecked Sendable {
    private var counter = 0

    func next() -> UUID {
        counter += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
    }

    /// Passed as the `makeID:` argument of the engine's factories.
    var make: () -> UUID { { self.next() } }
}

// MARK: - Seeded RNG

/// SplitMix64 — a two-line, well-distributed seeded generator. Reproducible
/// across platforms and runs, which is the only property the mutation
/// fuzzing needs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Fixtures

enum Fixture {
    /// A three-exercise routine with a per-item rest override on the last
    /// item, mirroring what the routine editor (§9) produces.
    static func routine(
        ids: SequentialIDs,
        setCounts: [Int] = [3, 4, 2],
        restOverrides: [TimeInterval?] = [nil, nil, 120]
    ) -> RoutineData {
        var items: [RoutineItemData] = []
        for (index, count) in setCounts.enumerated() {
            items.append(
                RoutineItemData(
                    id: ids.next(),
                    exerciseID: ids.next(),
                    order: index,
                    defaultSetCount: count,
                    restOverride: index < restOverrides.count ? restOverrides[index] : nil
                )
            )
        }
        return RoutineData(
            id: ids.next(),
            name: "Push A",
            orderIndex: 0,
            items: items,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000)
        )
    }

    /// A randomly shaped routine for the property-style suites.
    static func randomRoutine(using rng: inout SplitMix64, ids: SequentialIDs) -> RoutineData {
        let itemCount = Int.random(in: 1...6, using: &rng)
        var items: [RoutineItemData] = []
        for index in 0..<itemCount {
            items.append(
                RoutineItemData(
                    id: ids.next(),
                    exerciseID: ids.next(),
                    order: index,
                    defaultSetCount: Int.random(in: 0...5, using: &rng),
                    restOverride: Bool.random(using: &rng)
                        ? TimeInterval(Int.random(in: 1...20, using: &rng) * 15)
                        : nil
                )
            )
        }
        return RoutineData(
            id: ids.next(),
            name: "Generated",
            orderIndex: 0,
            items: items,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000)
        )
    }

    /// A last-performance digest for `exerciseID` with `count` sets.
    static func digest(
        exerciseID: UUID,
        weightsKg: [Double],
        reps: [Int]
    ) -> ExerciseLastPerformanceData {
        ExerciseLastPerformanceData(
            exerciseID: exerciseID,
            performedAt: Date(timeIntervalSince1970: 1_799_500_000),
            sets: zip(weightsKg, reps).map { SetSnapshot(weight: Weight(kg: $0), reps: $1) }
        )
    }
}

// MARK: - Encoding helpers

/// Round-trips a value through JSON, standing in for the crash-journal /
/// store boundary (§2 recovery, §3 "survives crash and appears correctly
/// on Resume").
func roundTripJSON<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}
