// SPDX-License-Identifier: GPL-3.0-or-later
// Session — spec §1 entity. Module-internal (see Exercise.swift).

import Foundation
import SwiftData
import BurlyCore

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    /// Denormalized routine provenance (§1): the pair survives routine
    /// archival *and* routine deletion, which is why Session holds no
    /// object relationship to Routine at all.
    var routineID: UUID?
    var routineName: String?
    var startedAt: Date
    var endedAt: Date?
    var state: SessionState
    /// Starts at 1; phone edits increment; sync compares it (§5).
    var revision: Int
    /// Link to the HKWorkout, set by the watch (§4 metadata ExternalUUID).
    var healthKitWorkoutID: UUID?
    var origin: SessionOrigin
    /// Spec §1: cascade delete, default `[]`. Ordering truth is
    /// `SessionItem.order`; mapping sorts by it.
    @Relationship(deleteRule: .cascade, inverse: \SessionItem.session)
    var items: [SessionItem] = []
    var notes: String?

    init(
        id: UUID,
        routineID: UUID?,
        routineName: String?,
        startedAt: Date,
        endedAt: Date?,
        state: SessionState,
        revision: Int,
        healthKitWorkoutID: UUID?,
        origin: SessionOrigin,
        notes: String?
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
        self.notes = notes
    }
}
