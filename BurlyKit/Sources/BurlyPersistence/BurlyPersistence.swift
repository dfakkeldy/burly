// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPersistence — the local store for Burly (spec §1, architecture doc
// option A: SwiftData, Dan's pick 2026-07-31).
//
// ## Layout
//
// - `Models/` — the seven `@Model` final classes for §1's entities. All
//   **internal**: `@Model` classes are not Sendable and must not cross a
//   module or actor boundary. `BurlyCore`'s `…Data` value types are what
//   callers see.
// - `Schema/` — `BurlySchemaV1` (`VersionedSchema`), `BurlyMigrationPlan`
//   (`SchemaMigrationPlan`, empty at v1), and `BurlyContainer`, the only
//   public way to make a container. Every container is built through the
//   plan so v2 is an append (§1 acceptance #5).
// - `Store/` — `BurlyStore`, the small protocol the architecture doc puts in
//   front of this module, plus the SwiftData implementation and the
//   model→value mapping. Swapping SwiftData out means reimplementing
//   `BurlyStore`; nothing else in the app changes.
//
// ## The two structural guarantees
//
// - **No hard-delete of an Exercise.** `BurlyStore` has no such method, so
//   the call cannot be written (§1 acceptance #3). `Exercise`'s
//   relationships also declare `.deny`, but SwiftData does not enforce it —
//   see Models/Exercise.swift. The absent method is the whole guarantee.
// - **kg is the only weight ever stored.** The store accepts weights only as
//   `BurlyCore.Weight`, which is kg-canonical by construction; lb is a
//   display-layer conversion (§1 acceptance #4).

import BurlyCore

public enum BurlyPersistence {
    public static let placeholder = "BurlyPersistence"
}
