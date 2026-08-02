// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPersistence — the local store for Burly (spec §1, architecture doc
// option A: SwiftData, Dan's pick 2026-07-31).
//
// ## Layout
//
// - `Models/` — the seven `@Model` final classes for §1's entities, plus
//   the §9 catalog seed-version metadata model and the §2 active-session
//   journal. All **internal**, and not because the compiler makes them so:
//   the `@Model` macro attaches `Sendable`, so nothing stops a model object
//   from crossing an actor boundary if a signature lets it (m1-06 review,
//   finding m3 — see Store/BurlyStore.swift's threading note for the full
//   contract). Keeping them internal, and out of every `BurlyStore`
//   signature, is what holds the boundary. `BurlyCore`'s `…Data` value
//   types are what callers see.
// - `Schema/` — `BurlySchemaV1` (`VersionedSchema`), `BurlyMigrationPlan`
//   (`SchemaMigrationPlan`, empty at v1), and `BurlyContainer`, the
//   module-internal factory every container is built through, so v2 is an
//   append (§1 acceptance #5).
// - `Store/` — `BurlyStore`, the small protocol the architecture doc puts in
//   front of this module, plus the SwiftData implementation and the
//   model→value mapping. Swapping SwiftData out means reimplementing
//   `BurlyStore`; nothing else in the app changes.
//
// ## The three structural guarantees
//
// - **No hard-delete of an Exercise.** `BurlyStore` has no such method, so
//   the call cannot be written (§1 acceptance #3). `Exercise`'s
//   relationships also declare `.deny`, but SwiftData does not enforce it —
//   see Models/Exercise.swift. The absent method is the whole guarantee.
// - **kg is the only weight ever stored.** The store accepts weights only as
//   `BurlyCore.Weight`, which is kg-canonical by construction; lb is a
//   display-layer conversion (§1 acceptance #4).
// - **No public path yields a raw `ModelContainer`.** `ModelContainer`
//   exposes `.erase()`/`.deleteAllData()` — a bulk hard-delete of
//   *everything*, the whole-store version of the bypass the first
//   guarantee above forbids for one Exercise. `BurlyContainer` is
//   module-internal; the public store-construction surface is
//   `SwiftDataStore.phone(at:)` / `.watch(at:)` / `init(kind:at:)`, none of
//   which name `ModelContainer` (m1-04 review). See
//   Tests/BurlyPersistenceTests/ContainerBoundaryTests.swift.

import BurlyCore

public enum BurlyPersistence {
    public static let placeholder = "BurlyPersistence"
}
