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

    /// Upper bound for a legal `revision` line (m4-04 review round 1, major
    /// 7). §1 starts a session at revision 1 and only a phone edit ever
    /// moves it, one at a time (`BurlyStore.applyPhoneEdit`'s `+= 1`); no
    /// real session will ever come close to this bound in the lifetime of
    /// the app. It exists to catch a forged or corrupted wire value —
    /// `Int.max` chief among them — before it can reach that increment,
    /// where overflowing `Int` traps the process instead of throwing. A
    /// wire payload's revision is checked against this range at decode time
    /// below; the store re-checks it at apply time (`BurlyStore
    /// .applyReplicatedSession`, `.createSession`) for callers that never
    /// went through `Decodable` at all.
    public static let maximumRevision = 1_000_000_000

    /// True for the one legal §1/§5 revision range: `1...maximumRevision`.
    /// `0` and negative values are never legal — §1: "starts at 1."
    public var hasValidRevision: Bool {
        (1...Self.maximumRevision).contains(revision)
    }

    /// Custom decoder for §1 default symmetry: `state` defaults to
    /// `.active`, `revision` to 1, and `items` to `[]` when absent —
    /// matching the memberwise initializer's defaults. Also validates
    /// `revision` against `maximumRevision` (m4-04 review round 1, major
    /// 7) — a wire payload is the one ingress this type cannot trap on;
    /// a hostile or corrupted value must fail the decode with a normal,
    /// catchable `DecodingError`, the same way `Weight`'s decoder already
    /// rejects a hostile `weightKg`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        routineID = try container.decodeIfPresent(UUID.self, forKey: .routineID)
        routineName = try container.decodeIfPresent(String.self, forKey: .routineName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .active
        let decodedRevision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        guard (1...Self.maximumRevision).contains(decodedRevision) else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "revision must be in 1...\(Self.maximumRevision) (decoded \(decodedRevision))."
            )
        }
        revision = decodedRevision
        healthKitWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .healthKitWorkoutID)
        origin = try container.decode(SessionOrigin.self, forKey: .origin)
        items = try container.decodeIfPresent([SessionItemData].self, forKey: .items) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}
