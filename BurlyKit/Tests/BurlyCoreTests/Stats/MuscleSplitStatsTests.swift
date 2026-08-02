// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for MuscleSplitStats (spec §7 #3, acceptance #1):
// fractional attribution across multi-tagged exercises, hand-computed, and
// the "always sums to 100%" invariant.
import Testing
import Foundation
@testable import BurlyCore

@Suite("MuscleSplitStats: fractional attribution (§7 #3 fixture truth)")
struct MuscleSplitStatsTests {
    private static let benchPress = UUID() // tagged [chest, triceps] — n=2
    private static let legPress = UUID()   // tagged [quads] — n=1
    private static let untaggedCustom = UUID() // tagged [] — must be excluded
    // An id deliberately absent from the muscle-group map — simulates a set
    // whose exercise reference cannot be resolved.
    private static let unresolved = UUID()

    private static let muscleGroups: [UUID: [MuscleGroup]] = [
        benchPress: [.chest, .triceps],
        legPress: [.quads],
        untaggedCustom: []
    ]

    private static func slice(exerciseID: UUID?, isWarmup: Bool = false) -> SetRecordSlice {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return SetRecordSlice(
            sessionID: UUID(),
            sessionStartedAt: date,
            exerciseID: exerciseID,
            set: SetRecordData(order: 0, weight: Weight(kg: 60), reps: 8, isWarmup: isWarmup, completedAt: date)
        )
    }

    @Test("2 bench sets (n=2 each) + 3 leg-press sets (n=1) split 20/20/60, summing to exactly 1.0")
    func fractionalSplitSumsToOne() {
        let slices = [
            Self.slice(exerciseID: Self.benchPress),
            Self.slice(exerciseID: Self.benchPress),
            // A warmup on a tagged exercise must not be counted at all.
            Self.slice(exerciseID: Self.benchPress, isWarmup: true),
            Self.slice(exerciseID: Self.legPress),
            Self.slice(exerciseID: Self.legPress),
            Self.slice(exerciseID: Self.legPress),
            // Untagged and unresolved: excluded from numerator AND
            // denominator, not counted as a zero-attribution set.
            Self.slice(exerciseID: Self.untaggedCustom),
            Self.slice(exerciseID: Self.unresolved),
            Self.slice(exerciseID: nil)
        ]

        let shares = MuscleSplitStats.fractionalSplit(from: slices, muscleGroupsByExerciseID: Self.muscleGroups)

        // Pool: 2 bench sets + 3 leg-press sets = 5 attributed sets.
        // chest:   2 × (1/2) / 5 = 1.0 / 5 = 0.2
        // triceps: 2 × (1/2) / 5 = 1.0 / 5 = 0.2
        // quads:   3 × (1/1) / 5 = 3.0 / 5 = 0.6
        #expect(shares.count == 3)
        #expect(shares.map(\.muscleGroup) == [.chest, .triceps, .quads]) // MuscleGroup.allCases order
        #expect(abs(shares[0].fraction - 0.2) < 0.000_001)
        #expect(abs(shares[1].fraction - 0.2) < 0.000_001)
        #expect(abs(shares[2].fraction - 0.6) < 0.000_001)

        let total = shares.reduce(0) { $0 + $1.fraction }
        #expect(abs(total - 1.0) < 0.000_001)
    }

    @Test("no attributable sets at all produces an empty split, not NaN")
    func noAttributableSetsProducesEmptyResult() {
        let slices = [
            Self.slice(exerciseID: Self.untaggedCustom),
            Self.slice(exerciseID: Self.unresolved),
            Self.slice(exerciseID: nil)
        ]
        #expect(MuscleSplitStats.fractionalSplit(from: slices, muscleGroupsByExerciseID: Self.muscleGroups).isEmpty)
    }

    @Test("a single-tag exercise attributes its full set to one group")
    func singleTagGetsFullAttribution() {
        let shares = MuscleSplitStats.fractionalSplit(
            from: [Self.slice(exerciseID: Self.legPress)],
            muscleGroupsByExerciseID: Self.muscleGroups
        )
        #expect(shares == [MuscleGroupShare(muscleGroup: .quads, fraction: 1.0)])
    }
}
