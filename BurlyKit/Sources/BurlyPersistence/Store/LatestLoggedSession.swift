// SPDX-License-Identifier: MIT
// LatestLoggedSession — the one "which logged session is latest" rule the
// §5 digest uses, shared by the store's narrow read and the generator
// (issue #24).
//
// The digest's per-exercise winner used to be decided in exactly one place,
// `SessionDigestGenerator.latestPerformancePerExercise`, over every logged
// set the phone holds. The narrow read
// (`BurlyStore.latestLoggedSetSlices(forExercises:)`) now picks the winning
// session inside the store, and the generator only ever sees that session's
// sets. If the two sides kept separate copies of the rule and disagreed on
// a tie, the generator could not notice: the session it would have chosen
// is no longer in its input. So both call this one function.
import Foundation
import BurlyCore

public enum LatestLoggedSession {
    /// `true` when `candidate` is later than `current`: it started later,
    /// or, on an exact `startedAt` tie (rare with real clocks, common with
    /// coarse or synthetic ones), its session id sorts higher as a string.
    /// Either way the answer is a pure function of the two pairs, never of
    /// fetch order.
    public static func isLater(
        _ candidate: (startedAt: Date, sessionID: UUID),
        than current: (startedAt: Date, sessionID: UUID)
    ) -> Bool {
        if candidate.startedAt != current.startedAt {
            return candidate.startedAt > current.startedAt
        }
        return candidate.sessionID.uuidString > current.sessionID.uuidString
    }

    /// The slices of each requested exercise's latest session, and nothing
    /// else, picked from an arbitrary slice list with `isLater`. This is the
    /// reference answer for `BurlyStore.latestLoggedSetSlices(forExercises:)`:
    /// the protocol's fallback implementation is this over
    /// `allLoggedSetSlices()`, and the tests hold `SwiftDataStore`'s narrow
    /// read to it.
    ///
    /// A slice with a `nil` exercise is never returned (nothing can request
    /// it). Order is unspecified; the digest generator sorts what it keeps.
    public static func winningSlices(
        from slices: [SetRecordSlice],
        forExercises exerciseIDs: Set<UUID>
    ) -> [SetRecordSlice] {
        var winners: [UUID: (startedAt: Date, sessionID: UUID)] = [:]
        for slice in slices {
            guard let exerciseID = slice.exerciseID, exerciseIDs.contains(exerciseID) else { continue }
            let candidate = (startedAt: slice.sessionStartedAt, sessionID: slice.sessionID)
            if let current = winners[exerciseID], !isLater(candidate, than: current) { continue }
            winners[exerciseID] = candidate
        }
        return slices.filter { slice in
            guard let exerciseID = slice.exerciseID else { return false }
            return winners[exerciseID]?.sessionID == slice.sessionID
        }
    }
}
