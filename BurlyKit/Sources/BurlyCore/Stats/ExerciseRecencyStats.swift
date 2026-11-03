// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ExerciseRecencyStats
//
// Spec §7 #1 names the progression chart's ranges but no default exercise.
// Opening on a fixed catalog name (Back Squat) showed "No working sets in
// this range" to anyone who doesn't squat, even when every other chart had
// data. These helpers pick what the chart opens on and which exercises the
// picker leads with, from whatever bounded slice window the caller fetched
// (the phone uses the longest §7 window, 52 weeks), so the §7 rule that
// all-exercise stats queries stay window-bounded still holds.
import Foundation

public enum ExerciseRecencyStats {
    /// The exercise the most recent session started with: among working
    /// sets that name an exercise, take the latest session (by
    /// `sessionStartedAt`, then session id so equal start times stay
    /// deterministic), then the exercise of its earliest-completed working
    /// set. `nil` when no working set names an exercise.
    ///
    /// Every slice of one session shares `sessionStartedAt`, so "latest"
    /// alone ties every exercise in that session. The opening lift breaks
    /// the tie rather than the last set: a workout usually starts with its
    /// main lift and ends with accessories or bodyweight work, whose chart
    /// would be a flat line at 0 kg.
    public static func openingExerciseOfLatestSession(from slices: [SetRecordSlice]) -> UUID? {
        let candidates = slices.filter { !$0.set.isWarmup && $0.exerciseID != nil }
        guard let latest = candidates.max(by: isInEarlierSession) else { return nil }
        return candidates
            .filter { $0.sessionID == latest.sessionID }
            .sortedForDeterministicSummation()
            .first?
            .exerciseID
    }

    /// Every exercise with at least one working set in `slices`. Warmups
    /// don't count, matching progression, volume and the split, which all
    /// exclude them (spec §7).
    public static func trainedExerciseIDs(from slices: [SetRecordSlice]) -> Set<UUID> {
        Set(slices.lazy.filter { !$0.set.isWarmup }.compactMap(\.exerciseID))
    }

    /// What the progression picker offers, in the given order: every active
    /// exercise, plus archived ones in `trainedIDs`. Archiving takes an
    /// exercise out of the pickers you plan with, but its recent history is
    /// still worth charting.
    public static func pickerExercises(_ exercises: [ExerciseData], trainedIDs: Set<UUID>) -> [ExerciseData] {
        exercises.filter { $0.archivedAt == nil || trainedIDs.contains($0.id) }
    }

    private static func isInEarlierSession(_ lhs: SetRecordSlice, _ rhs: SetRecordSlice) -> Bool {
        lhs.sessionStartedAt == rhs.sessionStartedAt
            ? lhs.sessionID.uuidString < rhs.sessionID.uuidString
            : lhs.sessionStartedAt < rhs.sessionStartedAt
    }
}
