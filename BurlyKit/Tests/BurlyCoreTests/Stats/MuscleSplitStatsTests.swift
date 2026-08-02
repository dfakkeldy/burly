// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for MuscleSplitStats (spec §7 #3, acceptance #1):
// fractional attribution across multi-tagged exercises, hand-computed, and
// the "always sums to 100%" invariant — now including the unattributed
// remainder (m6-01 fix round 1, major #6).
import Testing
import Foundation
@testable import BurlyCore

@Suite("MuscleSplitStats: fractional attribution (§7 #3 fixture truth)")
struct MuscleSplitStatsTests {
    private static let benchPress = UUID() // tagged [chest, triceps] — n=2
    private static let legPress = UUID()   // tagged [quads] — n=1
    private static let untaggedCustom = UUID() // tagged [] — must be explicitly unattributed
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

    @Test("2 bench sets (n=2 each) + 3 leg-press sets (n=1) + 3 unattributed sets split 12.5/12.5/37.5/37.5")
    func fractionalSplitIncludesUnattributedInTheDenominator() {
        let slices = [
            Self.slice(exerciseID: Self.benchPress),
            Self.slice(exerciseID: Self.benchPress),
            // A warmup on a tagged exercise must not be counted at all.
            Self.slice(exerciseID: Self.benchPress, isWarmup: true),
            Self.slice(exerciseID: Self.legPress),
            Self.slice(exerciseID: Self.legPress),
            Self.slice(exerciseID: Self.legPress),
            // Untagged and unresolved: cannot be assigned to any muscle
            // group, but ARE counted in the denominator via
            // `unattributedFraction` (m6-01 fix round 1, major #6) —
            // never silently dropped the way a warmup is.
            Self.slice(exerciseID: Self.untaggedCustom),
            Self.slice(exerciseID: Self.unresolved),
            Self.slice(exerciseID: nil)
        ]

        let summary = MuscleSplitStats.fractionalSplit(from: slices, muscleGroupsByExerciseID: Self.muscleGroups)

        // Denominator: 2 bench + 3 leg-press + 3 unattributed = 8 working
        // sets (the warmup is excluded, not counted anywhere).
        // chest:   2 × (1/2) / 8 = 1.0 / 8 = 0.125
        // triceps: 2 × (1/2) / 8 = 1.0 / 8 = 0.125
        // quads:   3 × (1/1) / 8 = 3.0 / 8 = 0.375
        // unattributed: 3 / 8 = 0.375
        #expect(summary.shares.count == 3)
        #expect(summary.shares.map(\.muscleGroup) == [.chest, .triceps, .quads]) // MuscleGroup.allCases order
        #expect(abs(summary.shares[0].fraction - 0.125) < 0.000_001)
        #expect(abs(summary.shares[1].fraction - 0.125) < 0.000_001)
        #expect(abs(summary.shares[2].fraction - 0.375) < 0.000_001)
        #expect(abs(summary.unattributedFraction - 0.375) < 0.000_001)

        let total = summary.shares.reduce(summary.unattributedFraction) { $0 + $1.fraction }
        #expect(total == 1.0)
    }

    @Test("no working sets in the window at all produces a genuinely empty (zero-sum) result, not NaN")
    func noWorkingSetsProducesZeroSumResult() {
        let summary = MuscleSplitStats.fractionalSplit(from: [], muscleGroupsByExerciseID: Self.muscleGroups)
        #expect(summary.shares.isEmpty)
        #expect(summary.unattributedFraction == 0)
    }

    @Test("a single-tag exercise attributes its full set to one group, with zero unattributed")
    func singleTagGetsFullAttribution() {
        let summary = MuscleSplitStats.fractionalSplit(
            from: [Self.slice(exerciseID: Self.legPress)],
            muscleGroupsByExerciseID: Self.muscleGroups
        )
        #expect(summary.shares == [MuscleGroupShare(muscleGroup: .quads, fraction: 1.0)])
        #expect(summary.unattributedFraction == 0)
    }

    // MARK: - Major #6 fix: zero-tag exercises are explicit, not silently dropped

    @Test("all-untagged history reports 100% unattributed, never an empty 'complete' 0% split (major #6 fix)")
    func allUntaggedHistoryReportsFullyUnattributed() {
        // The exact review scenario: one working set for a zero-tag
        // exercise. Before the fix this returned `[]`, which a naive
        // `reduce(0, +)` treats identically to "no data at all" — a
        // silent, misleadingly-"complete" 0% split.
        let summary = MuscleSplitStats.fractionalSplit(
            from: [Self.slice(exerciseID: Self.untaggedCustom)],
            muscleGroupsByExerciseID: Self.muscleGroups
        )
        #expect(summary.shares.isEmpty)
        #expect(summary.unattributedFraction == 1.0)
    }

    @Test("one tagged set among nine untagged ones is NOT displayed as 100% of the work (major #6 fix)")
    func mostlyUntaggedHistoryDoesNotOverstateTheTaggedShare() {
        // Reachable via SessionMutator.addPlaceholderExercise, which
        // deliberately creates zero-tag placeholder exercises for the
        // watch's "Custom (name later)" flow — this is not corrupted
        // input.
        var slices = [Self.slice(exerciseID: Self.legPress)] // 1 tagged set
        slices.append(contentsOf: (0..<9).map { _ in Self.slice(exerciseID: Self.untaggedCustom) })

        let summary = MuscleSplitStats.fractionalSplit(from: slices, muscleGroupsByExerciseID: Self.muscleGroups)

        // Before the fix: [MuscleGroupShare(quads, 1.0)] — the tagged set
        // alone, displayed as a "complete" 100% split. Correct: quads is
        // 1/10 of all logged work, and 9/10 is unattributed.
        #expect(summary.shares == [MuscleGroupShare(muscleGroup: .quads, fraction: 0.1)])
        #expect(abs(summary.unattributedFraction - 0.9) < 0.000_001)
    }

    // MARK: - Minor fix: shares literally sum to 1.0

    @Test("shares plus the unattributed fraction sum to EXACTLY 1.0 at scale, not merely within floating-point tolerance (minor fix)")
    func sharesAndUnattributedSumToExactlyOneAtScale() {
        // ~50,000 three-tag working sets — the review's scale, at which
        // naive per-group division against a shared denominator drifted
        // to 1.0000000000006535.
        let tripleTagExercise = UUID()
        let muscleGroups: [UUID: [MuscleGroup]] = [tripleTagExercise: [.chest, .triceps, .shoulders]]
        let slices = (0..<50_000).map { _ in Self.slice(exerciseID: tripleTagExercise) }

        let summary = MuscleSplitStats.fractionalSplit(from: slices, muscleGroupsByExerciseID: muscleGroups)

        let total = summary.shares.reduce(summary.unattributedFraction) { $0 + $1.fraction }
        #expect(total == 1.0)
    }
}
