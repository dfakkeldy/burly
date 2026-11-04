// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #5 — the migration-scaffold gate.
//
// "BurlySchemaV1 registered; a migration-plan test instantiates the
//  container through the plan (proves wiring before v2 exists)."
//
// The point is to fail *now* if the plan is mis-wired, rather than at v2
// when a real user's store is on the line.
//
// m1-06 review, finding M3 added the second half: wiring was proved, but
// the *ladder* was not — v1 did not own its model types, so the promised
// cheap append was fiction. The models are now nested in `BurlySchemaV1`,
// and a migration spike runs the whole v2 procedure against a store file
// on disk.
//
// 2026-11-03: V1 shipped in TestFlight 0.9.1 and is frozen; V2 adds
// `SessionTombstone` through one lightweight stage. ShippedStoreMigrationTests
// opens stores the 0.9.1 code wrote through that stage.
//
// Everything in *this* file uses the production schema shapes only (V1 and
// its verbatim V2 copies), so it runs in the ordinary `swift test` pass. The spike does not: its v2
// reuses v1's entity names and must not share a process with these tests.
// It lives in MigrationSpikeTests.swift behind an environment gate — read
// that file's header for why, and for the two-invocation run recipe.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@MainActor
@Suite("§1 #5 — versioned schema and migration plan wiring")
struct MigrationPlanTests {

    /// What TestFlight 0.9.1 shipped. If this list changes, V1 was edited
    /// in place and every store that build created stops opening.
    static let shippedV1ModelNames = [
        "ActiveSessionJournal",
        "CatalogSeedState",
        "Exercise",
        "ExerciseLastPerformance",
        "Routine",
        "RoutineItem",
        "Session",
        "SessionItem",
        "SetRecord",
        "WatchSyncJournal"
    ]

    @Test("BurlySchemaV1 is version 1.0.0 and still lists exactly the ten models 0.9.1 shipped")
    func v1ListsTheShippedModels() {
        #expect(BurlySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))

        let names = BurlySchemaV1.models.map { String(describing: $0) }.sorted()
        #expect(names == Self.shippedV1ModelNames.sorted())
        #expect(Set(names).count == names.count)
    }

    @Test("BurlySchemaV2 is version 2.0.0: V1's models plus SessionTombstone, each exactly once")
    func v2ListsEveryPersistentModel() {
        #expect(BurlySchemaV2.versionIdentifier == Schema.Version(2, 0, 0))

        let names = BurlySchemaV2.models.map { String(describing: $0) }.sorted()
        #expect(names == (Self.shippedV1ModelNames + ["SessionTombstone"]).sorted())
        #expect(Set(names).count == names.count)
    }

    @Test("V2's copies of the V1 entities have V1's exact attributes and relationships")
    func v2CopiesV1Verbatim() {
        // A copy that drifted (a renamed, dropped or retyped property)
        // would turn the lightweight stage into a silent transformation of
        // every tester's history. Same names, same property names, same
        // optionality and value types, entity by entity.
        func shape(_ schema: Schema) -> [String: [String]] {
            var shapes: [String: [String]] = [:]
            for entity in schema.entities {
                let attributes: [String] = entity.attributes.map { attribute in
                    "\(attribute.name):\(attribute.valueType):\(attribute.isOptional):\(attribute.isUnique)"
                }
                let relationships: [String] = entity.relationships.map { relationship in
                    "\(relationship.name)->\(relationship.destination):\(relationship.deleteRule.rawValue):\(relationship.inverseName ?? "-")"
                }
                shapes[entity.name] = (attributes + relationships).sorted()
            }
            return shapes
        }

        let v1 = shape(Schema(versionedSchema: BurlySchemaV1.self))
        var v2 = shape(Schema(versionedSchema: BurlySchemaV2.self))
        let tombstone = v2.removeValue(forKey: "SessionTombstone")
        #expect(tombstone != nil)
        #expect(v2 == v1)
    }

    @Test("BurlyMigrationPlan is V1 then V2, with one stage between them")
    func planIsV1ThenV2() {
        #expect(BurlyMigrationPlan.schemas.count == 2)
        #expect(BurlyMigrationPlan.schemas[0].versionIdentifier == Schema.Version(1, 0, 0))
        #expect(BurlyMigrationPlan.schemas[1].versionIdentifier == Schema.Version(2, 0, 0))
        #expect(BurlyMigrationPlan.stages.count == 1)
    }

    @Test("the phone container is constructed through the migration plan and is usable")
    func phoneContainerGoesThroughThePlan() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        #expect(container.schema.entities.count == BurlySchemaV2.models.count)

        let store = SwiftDataStore(container: container)
        let exercise = Fixture.exercise(name: "Pull-up", muscleGroups: [.lats, .biceps])
        try store.createExercise(exercise)
        #expect(try store.exercise(id: exercise.id) == exercise)
    }

    @Test("the watch container is constructed through the migration plan and carries the digest entity")
    func watchContainerGoesThroughThePlan() throws {
        let container = try BurlyContainer.watch(at: .inMemory)
        let entityNames = Set(container.schema.entities.map(\.name))
        #expect(entityNames.contains("ExerciseLastPerformance"))
        #expect(entityNames.contains("Session"))
        #expect(entityNames.contains("Routine"))

        // The watch-only entity is reachable and latest-wins on upsert (§5).
        let store = SwiftDataStore(container: container)
        let exerciseID = UUID()
        try store.upsertLastPerformance(
            ExerciseLastPerformanceData(
                exerciseID: exerciseID,
                performedAt: Fixture.epoch,
                sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
            )
        )
        try store.upsertLastPerformance(
            ExerciseLastPerformanceData(
                exerciseID: exerciseID,
                performedAt: Fixture.epoch.addingTimeInterval(86_400),
                sets: [
                    SetSnapshot(weight: Weight(kg: 62.5), reps: 8),
                    SetSnapshot(weight: Weight(kg: 62.5), reps: 6)
                ]
            )
        )

        let digest = try #require(try store.lastPerformance(exerciseID: exerciseID))
        #expect(digest.performedAt == Fixture.epoch.addingTimeInterval(86_400))
        #expect(digest.sets.count == 2)
        #expect(digest.sets[0].weightKg == 62.5)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ExerciseLastPerformance>()) == 1)
    }

    @Test("a store written at the current version reopens through the plan with no stage to run")
    func reopeningACurrentStoreThroughThePlanIsANoOp() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let exercise = Fixture.exercise(name: "Dip", muscleGroups: [.chest, .triceps])
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(exercise)
        }

        // Same file, new container, same plan: the v2 → v2 path must be a
        // clean no-op rather than a "model incompatible" failure.
        let reopened = try SwiftDataStore(kind: .phone, at: .file(url))
        #expect(try reopened.exercise(id: exercise.id) == exercise)
    }

    @Test("phone and watch default store URLs are distinct")
    func defaultStoreURLsDoNotCollide() throws {
        let phone = try BurlyContainer.defaultStoreURL(for: .phone)
        let watch = try BurlyContainer.defaultStoreURL(for: .watch)
        #expect(phone != watch)
        #expect(phone.lastPathComponent == "Burly-phone.store")
        #expect(watch.lastPathComponent == "Burly-watch.store")
    }

    // MARK: - m1-06 M3 — each version owns its models

    @Test("every model a version registers is declared inside that version, not beside it")
    func eachVersionOwnsItsModelTypes() {
        // The finding this pins: while the model classes were top-level,
        // editing one for v2 retroactively changed what v1 meant.
        // `String(reflecting:)` gives the fully qualified name, so a model
        // that drifts back out to file scope fails here.
        for model in BurlySchemaV1.models {
            let qualified = String(reflecting: model)
            #expect(
                qualified.hasPrefix("BurlyPersistence.BurlySchemaV1."),
                "\(qualified) is not owned by BurlySchemaV1"
            )
        }
        for model in BurlySchemaV2.models {
            let qualified = String(reflecting: model)
            #expect(
                qualified.hasPrefix("BurlyPersistence.BurlySchemaV2."),
                "\(qualified) is not owned by BurlySchemaV2"
            )
        }
        // V2 copies, never reaches back: a V2 model that was V1's type would
        // let a V3 edit rewrite V2 the way this rule exists to prevent.
        #expect(ObjectIdentifier(BurlySchemaV2.Exercise.self) != ObjectIdentifier(BurlySchemaV1.Exercise.self))
        #expect(ObjectIdentifier(BurlySchemaV2.SetRecord.self) != ObjectIdentifier(BurlySchemaV1.SetRecord.self))

        // …and the unqualified names the module uses everywhere else are
        // that same set of types, reached through the one typealias block
        // (Schema/CurrentSchema.swift) that a version bump repoints.
        #expect(Exercise.self == BurlySchemaV2.Exercise.self)
        #expect(Session.self == BurlySchemaV2.Session.self)
        #expect(SetRecord.self == BurlySchemaV2.SetRecord.self)
        #expect(ActiveSessionJournal.self == BurlySchemaV2.ActiveSessionJournal.self)
        #expect(SessionTombstone.self == BurlySchemaV2.SessionTombstone.self)
    }
}
