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

    private enum CodingKeys: String, CodingKey {
        case id, routineID, routineName, startedAt, endedAt, state, revision, healthKitWorkoutID, origin, items, notes
    }

    /// Custom decoder for §1 default symmetry: `state` defaults to
    /// `.active`, `revision` to 1, and `items` to `[]` when absent —
    /// matching the memberwise initializer's defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        routineID = try container.decodeIfPresent(UUID.self, forKey: .routineID)
        routineName = try container.decodeIfPresent(String.self, forKey: .routineName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .active
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        healthKitWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .healthKitWorkoutID)
        origin = try container.decode(SessionOrigin.self, forKey: .origin)
        items = try container.decodeIfPresent([SessionItemData].self, forKey: .items) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}
