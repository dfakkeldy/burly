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
//
// **This enum owns its models.** Each one is declared in its own file under
// Models/ as `extension BurlySchemaV1 { @Model final class … }`, so `models`
// below resolves to *this version's* types rather than to shared top-level
// classes a later version could edit out from under it (m1-06 review,
// finding M3). Schema/CurrentSchema.swift carries the typealias block that
// lets the rest of the module go on saying plain `Exercise`, and spells out
// the v2 procedure.
//
// Once v1 ships, the declarations in Models/ are **frozen**: v2 gets its own
// nested copies in its own file, and this file is never edited again.

import Foundation
import SwiftData

enum BurlySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every §1 entity, in spec order, plus three pieces of module-internal
    /// bookkeeping placed next to what they serve: the §9 seed-version
    /// metadata immediately after Exercise, and the in-flight session
    /// journal immediately after Session, and watch-sync protocol facts at
    /// the end. Unqualified because they are
    /// members of this enum. One schema serves both devices; the phone/watch
    /// difference is *content* policy (which rows exist, and the watch's
    /// post-ack pruning — §1 store shape, §5 outbox), not a different entity
    /// set. Two schemas would mean two migration ladders to keep in step for
    /// no gain.
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
            ExerciseLastPerformance.self,
            WatchSyncJournal.self
        ]
    }
}
