// SPDX-License-Identifier: GPL-3.0-or-later
// §9 catalog seed entry point.

import BurlyCore

public enum SeedLoader {
    /// Applies a validated seed and returns the number of newly inserted
    /// exercises. Existing UUIDs are deliberately left completely untouched.
    @discardableResult
    public static func apply(
        _ seed: CatalogSeed,
        to store: SwiftDataStore
    ) throws -> Int {
        try store.applyCatalogSeed(seed)
    }

    /// Loads the versioned SPM resource (catalog plus Hevy aliases) and applies
    /// its exercises. Returning the seed gives the caller the co-versioned
    /// alias table for import matching without a second resource read.
    @discardableResult
    public static func applyBundled(to store: SwiftDataStore) throws -> CatalogSeed {
        let seed = try CatalogSeed.loadBundled()
        try apply(seed, to: store)
        return seed
    }
}
