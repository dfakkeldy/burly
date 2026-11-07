// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyMigrationPlan — the append-only migration ladder.
//
// Spec §1 acceptance #5: the plan existed, empty, and every container was
// built *through* it before v2 existed, so adding v2 was an append (one
// entry in `schemas`, one `MigrationStage` in `stages`) rather than a
// retrofit that has to reason about stores created without a plan.
//
// Never reorder or remove an entry. V1 is what TestFlight 0.9.1 created on
// every tester's phone and watch; it stays first, frozen, for as long as
// such a store could still be opened.
//
// That append is only cheap because each version owns its model types —
// v1's are declared inside `BurlySchemaV1` and v2's inside `BurlySchemaV2`,
// so writing a later version cannot change what an earlier one means.
// Schema/CurrentSchema.swift has the procedure. Two tests measure it:
// `ShippedStoreMigrationTests` opens stores the 0.9.1 code wrote (checked-in
// fixtures) through this plan, and the gated migration spike
// (MigrationSpikeTests) appends a throwaway test-only v3 to it.

import Foundation
import SwiftData

enum BurlyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BurlySchemaV1.self, BurlySchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// V2 adds one entity (`SessionTombstone`) and changes none, so an
    /// existing store needs only a new, empty table: SwiftData's inferred
    /// mapping covers it, and there is no row to transform.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: BurlySchemaV1.self,
        toVersion: BurlySchemaV2.self
    )
}
