// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySchemaV1 — spec §1: "Schema declared once in BurlyPersistence,
// registered as `BurlySchemaV1: VersionedSchema` with a
// `SchemaMigrationPlan` from day one (empty stage list at v1) — so v2 is an
// append, not a retrofit."
//
// Internal, not public: `models` is an array of the module-internal `@Model`
// classes, and nothing outside BurlyPersistence needs the schema. App
// targets get stores from `SwiftDataStore.phone`/`.watch`/`init(kind:at:)`
// (public) instead — `BurlyContainer` itself is internal too (m1-04 review:
// `ModelContainer` must never appear in a public signature of this module).

import Foundation
import SwiftData

enum BurlySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every §1 entity, in spec order, plus two pieces of module-internal
    /// bookkeeping placed next to what they serve: the §9 seed-version
    /// metadata immediately after Exercise, and the in-flight session
    /// journal immediately after Session. One schema serves both devices;
    /// the phone/watch difference is *content* policy (which rows exist, and
    /// the watch's post-ack pruning — §1 store shape, §5 outbox), not a
    /// different entity set. Two schemas would mean two migration ladders
    /// to keep in step for no gain.
    static var models: [any PersistentModel.Type] {
        [
            Exercise.self,
            CatalogSeedState.self,
            Routine.self,
            RoutineItem.self,
            Session.self,
            ActiveSessionJournal.self,
            SessionItem.self,
            SetRecord.self,
            ExerciseLastPerformance.self
        ]
    }
}
