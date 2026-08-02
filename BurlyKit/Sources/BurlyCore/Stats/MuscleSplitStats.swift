// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — MuscleSplitStats
//
// Spec §7 #3: fractional muscle-group attribution. A working set on an
// exercise tagged with `n` muscle groups (`ExerciseData.muscleGroups`)
// contributes `1/n` to each of the `n` groups. Warmups are excluded
// everywhere per §7.
//
// A set whose exercise is unresolved, or carries zero muscle tags, cannot
// be fractionally attributed to any group — but it is still real logged
// work, and it is a reachable shape, not corrupted input:
// `SessionMutator.addPlaceholderExercise` deliberately creates zero-tag
// placeholder exercises for the watch's "Custom (name later)" flow (m6-01
// fix round 1, major #6). Silently excluding it from the denominator, the
// way an unresolved exercise reference legitimately is, would let one
// tagged set out of ten untagged ones display as a "complete" 100% split —
// so unattributed work gets its own explicit share of the same
// denominator instead of vanishing from it.
import Foundation

/// One wedge of the muscle-split chart.
public struct MuscleGroupShare: Sendable, Equatable {
    public let muscleGroup: MuscleGroup
    /// `[0, 1]`.
    public let fraction: Double
}

/// The full result of one `MuscleSplitStats.fractionalSplit` call: the
/// attributed wedges plus the unattributed remainder, which together
/// always account for every working set considered (see
/// `unattributedFraction`'s doc for the exact invariant and its one
/// exception).
public struct MuscleSplitSummary: Sendable, Equatable {
    /// One `MuscleGroupShare` per muscle group that received any
    /// attribution, in `MuscleGroup`'s declaration order. Empty if no set
    /// in the window could be attributed to any group at all — which
    /// includes the "no working sets in the window" case (see
    /// `unattributedFraction`'s doc for how to tell that apart from "every
    /// set was unattributed").
    public let shares: [MuscleGroupShare]
    /// Fraction `[0, 1]` of all working sets in the window that could not
    /// be attributed to any muscle group: an unresolved exercise
    /// reference, or one tagged with zero muscle groups (m6-01 fix round
    /// 1, major #6 — see the file doc for why this is a real, reachable
    /// path rather than corrupted input).
    ///
    /// **Invariant:** `shares.map(\.fraction).reduce(0, +) +
    /// unattributedFraction == 1.0` exactly (see `fractionalSplit`'s doc
    /// for the normalization that makes this literal, not merely "close
    /// to 1.0") whenever the window contained at least one working set.
    /// The one exception is genuinely empty input — no working sets at
    /// all — where both `shares` and `unattributedFraction` are zero,
    /// which is how a caller distinguishes "no data" (sums to 0) from
    /// "all of it was unattributed" (sums to 1, `shares` is empty,
    /// `unattributedFraction` is 1.0). A split can never silently present
    /// as a "complete" 0% or 100% split when the truth is "the app has no
    /// idea," because those two states no longer look identical.
    public let unattributedFraction: Double
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
    public static func fractionalSplit(
        from slices: [SetRecordSlice],
        muscleGroupsByExerciseID: [UUID: [MuscleGroup]]
    ) -> MuscleSplitSummary {
        var totals: [MuscleGroup: Double] = [:]
        var attributedSetCount = 0.0
        var unattributedSetCount = 0.0

        // Deterministic visitation order (m6-01 fix round 2, review item
        // 8 — "anywhere else totals accumulate"): the same reasoning as
        // `VolumeStats.weeklyVolume`'s doc applies here too — a fetch order
        // `BurlyStore.loggedSetSlices` never promised should not be able to
        // change the last few ULPs of a reported share.
        for slice in slices.sortedForDeterministicSummation() where !slice.set.isWarmup {
            guard
                let exerciseID = slice.exerciseID,
                let groups = muscleGroupsByExerciseID[exerciseID],
                groups.isEmpty == false
            else {
                // Zero-tag or unresolved: real logged work that cannot be
                // fractionally attributed to any group. Counted into the
                // denominator via `unattributedSetCount`, never dropped —
                // see the file doc.
                unattributedSetCount += 1
                continue
            }

            let share = 1.0 / Double(groups.count)
            for group in groups {
                totals[group, default: 0] += share
            }
            attributedSetCount += 1
        }

        let totalSetCount = attributedSetCount + unattributedSetCount
        guard totalSetCount > 0 else {
            // No working sets in the window at all — distinct from "every
            // set was unattributed" (see `unattributedFraction`'s doc).
            return MuscleSplitSummary(shares: [], unattributedFraction: 0)
        }

        let rawShares: [(MuscleGroup, Double)] = MuscleGroup.allCases.compactMap { group in
            guard let total = totals[group] else { return nil }
            return (group, total / totalSetCount)
        }
        let rawUnattributed = unattributedSetCount / totalSetCount

        let (shares, unattributed) = normalize(rawShares: rawShares, rawUnattributed: rawUnattributed)
        return MuscleSplitSummary(
            shares: shares.map { MuscleGroupShare(muscleGroup: $0.0, fraction: $0.1) },
            unattributedFraction: unattributed
        )
    }

    /// Rescales `rawShares` and `rawUnattributed` so they sum to
    /// *exactly* `1.0` in binary64, not merely "close to 1.0 within
    /// floating-point rounding" (m6-01 fix round 1, minor: literal
    /// sum-to-one). Dividing every component by the shared denominator
    /// already used to compute it (`totalSetCount` above) can still drift
    /// by a handful of ULPs at scale — measured: ~50,000 three-tag
    /// working sets drifted the naive sum to `1.0000000000006535` — so
    /// this instead divides by the *actual* sum of the raw fractions,
    /// then assigns whatever residual remains to the single largest
    /// component.
    ///
    /// **Rounding-remainder rule:** the residual (typically a few ULPs,
    /// exactly `0` once every component has already been divided by their
    /// own sum) always lands on the largest share (or `unattributedFraction`
    /// if it is the largest) — the wedge least likely to visibly change
    /// because of a last-decimal-place nudge, rather than an arbitrary or
    /// alphabetically-first one.
    private static func normalize(
        rawShares: [(MuscleGroup, Double)],
        rawUnattributed: Double
    ) -> (shares: [(MuscleGroup, Double)], unattributed: Double) {
        let rawSum = rawShares.reduce(rawUnattributed) { $0 + $1.1 }
        guard rawSum > 0 else { return (rawShares, rawUnattributed) }

        var values = rawShares.map { $0.1 / rawSum }
        var unattributed = rawUnattributed / rawSum

        let residual = 1.0 - values.reduce(unattributed, +)
        if residual != 0 {
            if let largestIndex = values.indices.max(by: { values[$0] < values[$1] }), values[largestIndex] >= unattributed {
                values[largestIndex] += residual
            } else {
                unattributed += residual
            }
        }

        return (zip(rawShares.map(\.0), values).map { ($0, $1) }, unattributed)
    }
}
