// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SetRecordSlice
//
// Flat, stats-shaped projection of one logged `SetRecord` (spec §7). Not a
// mirror of a spec §1 entity — see BurlyCore.swift's naming-scheme note for
// why the `<Entity>Data` suffix is reserved for those — so this is named
// for what it is: the *result* of a bounded BurlyPersistence stats query
// (`BurlyStore.loggedSetSlices`), not a storage-shaped value type in its
// own right.
//
// It exists so §7's PR, volume, and muscle-split computations never need
// the full Session → SessionItem → SetRecord object graph `sessions()`
// returns: one row here carries exactly what a chart needs — which session
// and exercise the set belongs to, and the set itself — with nothing left
// to fault. See `BurlyStore.loggedSetSlices`'s doc for the query this backs
// and why it is bounded the way it is.
//
// Imports Foundation only for `UUID`/`Date`, same as every other BurlyCore
// file that touches identity or time.
import Foundation

public struct SetRecordSlice: Sendable, Equatable, Hashable {
    /// Which session this set belongs to — the PR chart's per-session
    /// grouping key (spec §7 #1: "top-set weight per session").
    public let sessionID: UUID

    /// The session's `startedAt`, not the set's own `completedAt`: every
    /// set in one session shares this value, which is what makes it usable
    /// as that session's single chart date. A session's sets can span a
    /// real amount of wall-clock time (and, rarely, straddle midnight); the
    /// session's date should not vary set-to-set within it.
    public let sessionStartedAt: Date

    /// The exercise this set was logged against, or `nil` if the session
    /// item names none (spec §1 allows `exercise: Exercise?`). A `nil` set
    /// cannot be exercise-filtered or muscle-attributed; see
    /// `MuscleSplitStats` for how that case is excluded rather than
    /// mis-attributed.
    public let exerciseID: UUID?

    /// The set itself — same validated `Weight`, `reps`, `isWarmup`,
    /// `completedAt` shape used everywhere else in BurlyCore.
    public let set: SetRecordData

    public init(sessionID: UUID, sessionStartedAt: Date, exerciseID: UUID?, set: SetRecordData) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.exerciseID = exerciseID
        self.set = set
    }
}
