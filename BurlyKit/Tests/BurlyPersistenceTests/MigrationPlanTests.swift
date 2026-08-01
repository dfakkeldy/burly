// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #5 — the migration-scaffold gate.
//
// "BurlySchemaV1 registered; a migration-plan test instantiates the
//  container through the plan (proves wiring before v2 exists)."
//
// The point is to fail *now* if the plan is mis-wired, rather than at v2
// when a real user's store is on the line.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 #5 — versioned schema and migration plan wiring")
struct MigrationPlanTests {

    @Test("BurlySchemaV1 is version 1.0.0 and lists every persistent model exactly once")
    func schemaListsEveryPersistentModel() {
        #expect(BurlySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))

        let names = BurlySchemaV1.models.map { String(describing: $0) }.sorted()
        #expect(names == [
            "CatalogSeedState",
            "Exercise",
            "ExerciseLastPerformance",
            "Routine",
            "RoutineItem",
            "SessionItem",
            "Session",
            "SetRecord"
        ].sorted())
        #expect(Set(names).count == names.count)
    }

    @Test("BurlyMigrationPlan has v1 registered and no stages yet")
    func planIsEmptyAtV1() {
        #expect(BurlyMigrationPlan.schemas.count == 1)
        #expect(BurlyMigrationPlan.schemas[0].versionIdentifier == Schema.Version(1, 0, 0))
        #expect(BurlyMigrationPlan.stages.isEmpty)
    }

    @Test("the phone container is constructed through the migration plan and is usable")
    func phoneContainerGoesThroughThePlan() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        #expect(container.schema.entities.count == BurlySchemaV1.models.count)

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

    @Test("a store written at v1 reopens through the plan with no migration stages to run")
    func reopeningAV1StoreThroughThePlanIsANoOp() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let exercise = Fixture.exercise(name: "Dip", muscleGroups: [.chest, .triceps])
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(exercise)
        }

        // Same file, new container, same plan: the v1 → v1 path must be a
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
}
