// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySchemaV1 — spec §1: "Schema declared once in BurlyPersistence,
// registered as `BurlySchemaV1: VersionedSchema` with a
// `SchemaMigrationPlan` from day one (empty stage list at v1) — so v2 is an
// append, not a retrofit."
//
// Internal, not public: `models` is an array of the module-internal `@Model`
// classes, and nothing outside BurlyPersistence needs the schema. App
// targets get containers from `BurlyContainer` (public) instead.

import Foundation
import SwiftData

enum BurlySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every §1 entity, in spec order. One schema serves both devices; the
    /// phone/watch difference is *content* policy (which rows exist, and
    /// the watch's post-ack pruning — §1 store shape, §5 outbox), not a
    /// different entity set. Two schemas would mean two migration ladders
    /// to keep in step for no gain.
    static var models: [any PersistentModel.Type] {
        [
            Exercise.self,
            Routine.self,
            RoutineItem.self,
            Session.self,
            SessionItem.self,
            SetRecord.self,
            ExerciseLastPerformance.self
        ]
    }
}
