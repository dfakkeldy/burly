// SPDX-License-Identifier: GPL-3.0-or-later
// The current-schema façade — one file, one block, the whole cost of a
// version bump.
//
// ## What this fixes
//
// The m1-06 review (finding M3) found that `BurlySchemaV1.models` pointed
// at *top-level* `@Model` classes. That made V1 a name, not a snapshot:
// adding a field for v2 would have edited the same `Exercise` class V1
// claims to describe, so "V1" would retroactively mean something else, and
// the promised cheap append would in fact have been a whole-layer rewrite
// (version-scoped copies of every affected model, plus a same-commit
// retarget of the store, predicates, relationships, mappings and tests).
//
// So every model is now declared inside `BurlySchemaV1` (Models/*.swift,
// each `extension BurlySchemaV1 { @Model final class … }`). V1 owns its
// types; freezing it is now just "do not edit those declarations".
//
// ## What this file is
//
// Consuming code — `SwiftDataStore`, `ModelMapping`, predicates, tests —
// must not spell a version into every fetch. It names `Exercise`, and this
// block decides which version `Exercise` currently means.
//
// ## The v2 procedure
//
//  1. Add `Schema/BurlySchemaV2.swift` with `enum BurlySchemaV2:
//     VersionedSchema`, containing a nested copy of **every** model — a
//     `VersionedSchema` is a complete snapshot, not a diff — with the v2
//     change applied to the ones that change. Copy the unchanged ones
//     verbatim; do **not** reference `BurlySchemaV1.Foo` from V2, or V3
//     would silently mutate V2 the same way V2 would have mutated V1.
//  2. Append to `BurlyMigrationPlan`: one entry in `schemas`, one
//     `MigrationStage` in `stages`.
//  3. Point `Schema(versionedSchema:)` in BurlyContainer at V2.
//  4. Repoint the typealiases below. Nothing else in the module changes,
//     because nothing else names a version.
//
// Steps 1–4 are exactly what `MigrationPlanTests`' migration spike does
// against a real store file, so the ladder is measured rather than
// promised.
//
// The typealiases are internal for the same reason the model classes are
// (see Exercise.swift): nothing outside BurlyPersistence may name an
// `@Model` type.

/// The schema version the module's unqualified model names refer to.
/// Repoint together with the typealiases below on a version bump.
typealias BurlySchemaCurrent = BurlySchemaV1

typealias ActiveSessionJournal = BurlySchemaCurrent.ActiveSessionJournal
typealias CatalogSeedState = BurlySchemaCurrent.CatalogSeedState
typealias Exercise = BurlySchemaCurrent.Exercise
typealias ExerciseLastPerformance = BurlySchemaCurrent.ExerciseLastPerformance
typealias Routine = BurlySchemaCurrent.Routine
typealias RoutineItem = BurlySchemaCurrent.RoutineItem
typealias Session = BurlySchemaCurrent.Session
typealias SessionItem = BurlySchemaCurrent.SessionItem
typealias SetRecord = BurlySchemaCurrent.SetRecord
