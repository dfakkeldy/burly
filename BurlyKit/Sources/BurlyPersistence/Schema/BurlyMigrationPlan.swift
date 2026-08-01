// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyMigrationPlan — the day-one, deliberately empty migration ladder.
//
// Spec §1 acceptance #5: the plan exists and every container is built
// *through* it before v2 exists, so adding v2 is an append (one entry in
// `schemas`, one `MigrationStage` in `stages`) rather than a retrofit that
// has to reason about stores created without a plan.
//
// When v2 arrives:
//   schemas → [BurlySchemaV1.self, BurlySchemaV2.self]
//   stages  → [migrateV1toV2]        // .lightweight or .custom
// Never reorder or remove an entry; the ladder is append-only.
//
// That append is only cheap because each version owns its model types —
// v1's are declared inside `BurlySchemaV1`, so writing `BurlySchemaV2`
// cannot change what v1 means. Schema/CurrentSchema.swift has the full v2
// procedure; `MigrationPlanTests`' migration spike runs that procedure
// against a v1 store file on disk, so "v2 is an append" is measured rather
// than asserted. The spike's v2 lives in the test target only: this list
// stays `[BurlySchemaV1]` with no stages until a real v2 ships.

import Foundation
import SwiftData

enum BurlyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BurlySchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
