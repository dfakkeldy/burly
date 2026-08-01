// SPDX-License-Identifier: GPL-3.0-or-later
// Internal metadata for §9 catalog seed application.
//
// BurlySchemaV1 has not shipped, so registering this model in V1 is an
// additive completion of the initial schema, not a migration of user data.

import SwiftData

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
