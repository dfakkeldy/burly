// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SetPrefill, SetPrefillSource, SetPrefillResolver
//
// Spec §2 input model: "Prefill: weight/reps prefill from last session's
// same set index; fallback: previous set this session; fallback: empty."
//
// Three rungs, in that order, and the source is part of the result — the
// logging screen renders the ghost row differently depending on where the
// numbers came from, and "empty" must be visibly empty rather than a
// plausible-looking guess (§2 acceptance #5: "absent digest renders empty
// ghosts (no crash, no stale data)").
//
// The digest guard matters more than it looks: `ExerciseLastPerformance`
// is keyed by exercise, and a session item's exercise can change under it
// mid-session (`SessionMutator.swapExercise`). Resolving against a digest
// for the *previous* exercise would prefill a barbell row's numbers into a
// lat pulldown. The resolver therefore takes the item's exercise id and
// ignores any digest that does not match.
//
// Imports Foundation for `UUID` only.
import Foundation

/// Where a prefilled value came from (§2's three rungs).
public enum SetPrefillSource: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Last session's numbers for this same set index.
    case lastPerformance
    /// The previous set logged in this session for this exercise.
    case previousSetThisSession
    /// Nothing to go on.
    case empty
}

/// The values to seed the weight and reps controls with, plus provenance.
/// `weight` and `reps` are `nil` exactly when `source == .empty`.
public struct SetPrefill: Sendable, Equatable, Hashable {
    public var weight: Weight?
    public var reps: Int?
    public var source: SetPrefillSource

    public init(weight: Weight?, reps: Int?, source: SetPrefillSource) {
        self.weight = weight
        self.reps = reps
        self.source = source
    }

    public static let empty = SetPrefill(weight: nil, reps: nil, source: .empty)

    public var isEmpty: Bool { source == .empty }
}

public enum SetPrefillResolver {
    /// Resolves the prefill for the set about to be logged.
    ///
    /// - Parameters:
    ///   - exerciseID: the item's current exercise; a digest for any other
    ///     exercise is ignored.
    ///   - setIndex: the index of the set about to be logged — normally
    ///     `loggedSets.count`.
    ///   - loggedSets: sets already logged against this item this session.
    ///   - lastPerformance: the phone-pushed digest (§5), if any.
    public static func prefill(
        exerciseID: UUID?,
        setIndex: Int,
        loggedSets: [SetRecordData],
        lastPerformance: ExerciseLastPerformanceData?
    ) -> SetPrefill {
        if let digest = lastPerformance,
           let exerciseID,
           digest.exerciseID == exerciseID,
           setIndex >= 0,
           setIndex < digest.sets.count {
            let snapshot = digest.sets[setIndex]
            return SetPrefill(
                weight: snapshot.weight,
                reps: snapshot.reps,
                source: .lastPerformance
            )
        }

        // "Previous set this session" is the most recent one logged, which
        // for the usual `setIndex == loggedSets.count` is the set directly
        // above the one being entered.
        if let previous = loggedSets.last {
            return SetPrefill(
                weight: previous.weight,
                reps: previous.reps,
                source: .previousSetThisSession
            )
        }

        return .empty
    }

    /// The dimmed ghost row for a set index: last session's numbers for
    /// that index, or `nil` when the digest has nothing there (§2 —
    /// "displayed dimmed exactly where the current numbers will land").
    ///
    /// Deliberately *not* the same call as `prefill`: the ghost only ever
    /// shows last session, never this session's previous set, or the row
    /// would claim history it does not have.
    public static func ghost(
        exerciseID: UUID?,
        setIndex: Int,
        lastPerformance: ExerciseLastPerformanceData?
    ) -> SetSnapshot? {
        guard let digest = lastPerformance,
              let exerciseID,
              digest.exerciseID == exerciseID,
              setIndex >= 0,
              setIndex < digest.sets.count
        else { return nil }
        return digest.sets[setIndex]
    }
}
