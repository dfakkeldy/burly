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

extension Array where Element == SetRecordSlice {
    /// Deterministic visitation order for any computation that accumulates
    /// a total over `SetRecordSlice`s (m6-01 fix round 2, review item 8):
    /// sorted by the set's own `completedAt`, then by its stable `id` to
    /// fully break ties on identical timestamps.
    ///
    /// `BurlyStore.loggedSetSlices` promises no fetch ordering, and
    /// floating-point addition is not associative — even Kahan compensated
    /// summation (see `VolumeStats.weeklyVolume`) is far more *accurate*
    /// than naive `+=`, but it is not order-*independent*: summing the
    /// same contributions in two different visitation orders can still
    /// produce a bit-different total. Sorting into one canonical order
    /// before accumulating is what makes the result depend only on which
    /// SetRecords exist, never on the order the store happened to return
    /// them in. `VolumeStats.weeklyVolume` and `MuscleSplitStats
    /// .fractionalSplit` both sort with this before accumulating.
    func sortedForDeterministicSummation() -> [SetRecordSlice] {
        sorted { lhs, rhs in
            lhs.set.completedAt == rhs.set.completedAt
                ? lhs.set.id.uuidString < rhs.set.id.uuidString
                : lhs.set.completedAt < rhs.set.completedAt
        }
    }
}
