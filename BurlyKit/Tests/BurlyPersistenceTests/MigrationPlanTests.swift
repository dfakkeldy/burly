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
// and the "migration spike" section at the bottom of this file runs the
// whole v2 procedure against a store file on disk. See
// MigrationSpikeSchemaV2.swift for the throwaway v2 it migrates to.

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
            "ActiveSessionJournal",
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

    // MARK: - m1-06 M3 — v1 owns its models

    @Test("every model v1 registers is declared inside BurlySchemaV1, not beside it")
    func v1OwnsItsModelTypes() {
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

        // …and the unqualified names the module uses everywhere else are
        // that same set of types, reached through the one typealias block
        // (Schema/CurrentSchema.swift) that a version bump repoints.
        #expect(Exercise.self == BurlySchemaV1.Exercise.self)
        #expect(Session.self == BurlySchemaV1.Session.self)
        #expect(SetRecord.self == BurlySchemaV1.SetRecord.self)
        #expect(ActiveSessionJournal.self == BurlySchemaV1.ActiveSessionJournal.self)
    }

    // MARK: - m1-06 M3 — the migration spike

    @Test("the spike's v2 exists only in the test target; the shipping ladder is still v1-only")
    func theSpikeDoesNotLeakIntoTheShippingLadder() {
        #expect(BurlyMigrationPlan.schemas.count == 1)
        #expect(BurlyMigrationPlan.stages.isEmpty)

        // The spike ladder is the shipping one plus exactly one append —
        // which is what §1 acceptance #5 claims v2 will cost.
        #expect(MigrationSpikePlan.schemas.count == 2)
        #expect(MigrationSpikePlan.schemas[0].versionIdentifier == Schema.Version(1, 0, 0))
        #expect(MigrationSpikePlan.schemas[1].versionIdentifier == Schema.Version(2, 0, 0))
        #expect(MigrationSpikePlan.stages.count == 1)
    }

    @Test("a v1 store written to disk migrates through a real v1→v2 stage with its data intact")
    func aV1StoreSurvivesTheV1ToV2Stage() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])

        // 1. Write a v1 store through the *shipping* stage-free plan — the
        //    same code path a real user's store is created by.
        let sessionID: UUID
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: TestClock())
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createRoutine(routine)

            var active = SessionBuilder.session(from: routine, clock: TestClock())
            active.restTimer = RestTimerState(startedAt: Fixture.epoch, duration: 90)
            try store.saveActiveSession(active)
            sessionID = active.session.id

            try store.logSet(
                SetRecordData(
                    order: 0,
                    weight: Weight(kg: 102.5),
                    reps: 5,
                    completedAt: Fixture.epoch
                ),
                toSessionItem: active.session.items[0].id
            )
            try store.upsertLastPerformance(
                ExerciseLastPerformanceData(
                    exerciseID: bench.id,
                    performedAt: Fixture.epoch,
                    sets: [SetSnapshot(weight: Weight(kg: 100), reps: 5)]
                )
            )
        }

        // 2. Open that same file through a ladder that *does* have a
        //    v1 → v2 stage. If v1 were not a frozen, nameable snapshot this
        //    is the step that could not be written at all.
        spikeMigrationTrace.withLock { $0 = SpikeMigrationTrace() }
        let migrated = try openThroughSpikeLadder(.watch, at: url)
        let context = ModelContext(migrated)

        // The stage really ran, and each half saw the shape SwiftData
        // promises it: v1 named from `willMigrate`, v2 from `didMigrate`.
        // Both are only writable because each version owns its model types.
        #expect(spikeMigrationTrace.withLock(\.setRecordsSeenAsV1) == 1)
        #expect(spikeMigrationTrace.withLock(\.setRecordsSeenAsV2) == 1)

        // Row counts: nothing dropped, nothing duplicated.
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.Exercise>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.Routine>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.RoutineItem>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.Session>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.SessionItem>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.ActiveSessionJournal>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.ExerciseLastPerformance>()) == 1)
        // Never seeded in this test — the entity migrates even so.
        #expect(try context.fetchCount(FetchDescriptor<MigrationSpikeSchemaV2.CatalogSeedState>()) == 0)

        // Spot values: the set row came through byte-for-byte, including
        // the kg canonicalisation (§1 acceptance #4)…
        let set = try #require(
            try context.fetch(FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()).first
        )
        #expect(set.weightKg == 102.5)
        #expect(set.reps == 5)
        #expect(set.completedAt == Fixture.epoch)
        #expect(set.isWarmup == false)
        // …the new v2 column is present and empty on migrated rows…
        #expect(set.rpe == nil)
        // …and the relationships still resolve across the migration.
        #expect(set.sessionItem?.session?.id == sessionID)
        #expect(set.sessionItem?.exercise?.name == "Bench Press")

        let digest = try #require(
            try context.fetch(FetchDescriptor<MigrationSpikeSchemaV2.ExerciseLastPerformance>()).first
        )
        #expect(digest.exerciseID == bench.id)
        #expect(digest.sets.map(\.weightKg) == [100])

        let journal = try #require(
            try context.fetch(FetchDescriptor<MigrationSpikeSchemaV2.ActiveSessionJournal>()).first
        )
        #expect(journal.sessionID == sessionID)
        let scaffolding = try JSONDecoder().decode(
            ActiveSessionScaffolding.self,
            from: journal.payload
        )
        #expect(scaffolding.restTimer?.duration == 90)

        // 3. The migrated store is a working v2 store, not just a readable
        //    one: write the new column and prove it survives a reopen.
        set.rpe = 8.5
        try context.save()

        let reopened = ModelContext(try openThroughSpikeLadder(.watch, at: url))
        let reread = try #require(
            try reopened.fetch(FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()).first
        )
        #expect(reread.rpe == 8.5)
        #expect(reread.weightKg == 102.5)
    }
}
