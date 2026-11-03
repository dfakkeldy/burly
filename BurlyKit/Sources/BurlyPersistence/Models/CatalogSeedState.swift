// SPDX-License-Identifier: GPL-3.0-or-later
// Internal metadata for §9 catalog seed application.
//
// BurlySchemaV1 had not shipped when this was added, so registering it in V1
// was an additive completion of the initial schema, not a migration of user
// data. V1 is frozen since TestFlight 0.9.1 (2026-11-03): a later change goes
// in a new schema version (see Schema/CurrentSchema.swift and DECISIONS.md).
//
// Nested in `BurlySchemaV1` like every other model — see
// Schema/CurrentSchema.swift.

import SwiftData

extension BurlySchemaV1 {
    @Model
    final class CatalogSeedState {
        static let exerciseCatalogKey = "exerciseCatalog"

        @Attribute(.unique) var key: String
        var version: Int

        init(key: String = exerciseCatalogKey, version: Int) {
            self.key = key
            self.version = version
        }
    }
}
