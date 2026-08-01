// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionData
//
// Value-type mirror of the SwiftData `Session` entity (spec §1). See the
// module doc in BurlyCore.swift for the naming scheme this file follows.
//
// Imports Foundation for `UUID` (identity) and `Date` (startedAt,
// endedAt) only.
import Foundation

public struct SessionData: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID

    /// Denormalized (spec §1): `routineName` survives routine archival
    /// even though `routineID` still points at the (possibly archived)
    /// routine, for provenance.
    public var routineID: UUID?
    public var routineName: String?

    public var startedAt: Date
    public var endedAt: Date?

    /// Defaults to `.active`: every session begins that way (§2 — Start
    /// creates the session, then the logging screen).
    public var state: SessionState

    /// Starts at 1 (spec §1); phone edits increment it; sync uses it for
    /// idempotent upserts (an incoming revision ≤ stored revision is
    /// dropped, §5).
    public var revision: Int

    /// Links to the HKWorkout the watch created for this session (§4),
    /// set by the watch.
    public var healthKitWorkoutID: UUID?

    public var origin: SessionOrigin

    /// Spec's cascade-delete `items: [SessionItem]` relationship,
    /// embedded.
    public var items: [SessionItemData]
    public var notes: String?

    public init(
        id: UUID = UUID(),
        routineID: UUID? = nil,
        routineName: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        state: SessionState = .active,
        revision: Int = 1,
        healthKitWorkoutID: UUID? = nil,
        origin: SessionOrigin,
        items: [SessionItemData] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.revision = revision
        self.healthKitWorkoutID = healthKitWorkoutID
        self.origin = origin
        self.items = items
        self.notes = notes
    }
}
