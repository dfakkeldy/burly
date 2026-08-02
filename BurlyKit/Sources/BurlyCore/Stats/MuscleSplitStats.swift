// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — MuscleSplitStats
//
// Spec §7 #3: fractional muscle-group attribution. A working set on an
// exercise tagged with `n` muscle groups (`ExerciseData.muscleGroups`)
// contributes `1/n` to each of the `n` groups, so the split always sums to
// 1.0 (spec: "the split always sums to 100%") — over the sets it *can*
// attribute. Warmups are excluded everywhere per §7; a set whose exercise
// is unresolved or carries zero muscle tags cannot be fractionally
// attributed at all (there is no muscle-neutral share to give it) and is
// excluded from both the numerator and the denominator, so the invariant
// holds over whatever remains rather than being violated by an untagged
// edge case.
import Foundation

/// One wedge of the muscle-split chart.
public struct MuscleGroupShare: Sendable, Equatable {
    public let muscleGroup: MuscleGroup
    /// `[0, 1]`; every returned share sums to 1.0 (barring floating-point
    /// rounding in the last decimal place) across one
    /// `fractionalSplit(from:muscleGroupsByExerciseID:)` call, per spec §7.
    public let fraction: Double
}

public enum MuscleSplitStats {
    /// - Parameters:
    ///   - slices: working history for the window (§7 default: trailing
    ///     4 weeks), already date-bounded by the caller.
    ///   - muscleGroupsByExerciseID: `ExerciseData.muscleGroups`, keyed by
    ///     id, for every exercise `slices` might reference — typically all
    ///     of `BurlyStore.exercises(includingArchived: true)`, a catalog-
    ///     sized (~100 row, §9) fetch already established elsewhere in this
    ///     module as cheap enough to do in full.
    /// - Returns: one `MuscleGroupShare` per muscle group that received any
    ///   attribution, in `MuscleGroup`'s declaration order. Empty if no set
    ///   in `slices` could be attributed at all.
    public static func fractionalSplit(
        from slices: [SetRecordSlice],
        muscleGroupsByExerciseID: [UUID: [MuscleGroup]]
    ) -> [MuscleGroupShare] {
        var totals: [MuscleGroup: Double] = [:]
        var attributedSetCount = 0.0

        for slice in slices where !slice.set.isWarmup {
            guard
                let exerciseID = slice.exerciseID,
                let groups = muscleGroupsByExerciseID[exerciseID],
                groups.isEmpty == false
            else { continue }

            let share = 1.0 / Double(groups.count)
            for group in groups {
                totals[group, default: 0] += share
            }
            attributedSetCount += 1
        }

        guard attributedSetCount > 0 else { return [] }
        return MuscleGroup.allCases.compactMap { group in
            guard let total = totals[group] else { return nil }
            return MuscleGroupShare(muscleGroup: group, fraction: total / attributedSetCount)
        }
    }
}
