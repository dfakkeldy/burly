// SPDX-License-Identifier: GPL-3.0-or-later
// The migration spike's tests — **they must run in their own process.**
//
// ## Why this suite is gated behind an environment variable
//
// The spike's v2 (MigrationSpikeSchemaV2.swift) declares entities with the
// SAME NAMES as the production v1 schema. That is not sloppiness, it is the
// mechanism: SwiftData matches schemas across versions by entity name and
// shape, so a v2 whose entities were named differently would not be a
// migration of v1 at all — it would be a different database.
//
// The cost is that realising both shapes inside one process leaves two
// different definitions of "SetRecord", "Session", "Exercise" … alive at
// once. On the macOS 27 SwiftData build that is tolerated; on the macos-26
// build CI runs, it is not, and the damage lands *somewhere else*,
// nondeterministically:
//
//   - CI run 30724246601: the spike's own reopen read `rpe` back as `nil`
//     — the v1 shape (no `rpe`) shadowing v2.
//   - CI run 30724883683: the whole test process died on an uncaught
//     NSException in `KeyedEncodingContainer.encodeNil(forKey:)`, thrown
//     from a *production* `SwiftDataStore.logSet` inside
//     AckSeamIntegrationTests — a test that never touches the spike. That
//     is the v2 shape (with its extra optional `rpe`) shadowing v1 while an
//     ordinary store saved a set.
//
// Both directions, both nondeterministic, both consistent with a
// process-global entity registry keyed by name. Neither is reproducible on
// the developer's Darwin 27 machine (24/24 local repetitions passed), which
// is exactly why the isolation has to be structural rather than a fix aimed
// at whichever symptom surfaced last.
//
// So: the production-shape tests and the spike never share a process.
//
// ## Running it
//
// Full coverage is TWO invocations, and `swift test` alone is not enough:
//
//     swift test                                              # spike skipped
//     BURLY_RUN_MIGRATION_SPIKE=1 swift test \
//         --filter MigrationSpikeTests                        # spike only
//
// .github/workflows/ci.yml runs both as separate steps. There is no
// canonical local test script in Scripts/ to mirror this in; if one is ever
// added, it must run both.
//
// If CI ever fails here *again* with the spike skipped in the main run,
// then merely linking the v2 model classes into the test binary is enough
// to poison the registry, and the spike has to move out of this package
// entirely (its own package, built and run separately) rather than being
// gated at runtime.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite(
    "m1-06 M3 — migration spike (isolated process)",
    .enabled(
        if: migrationSpikeIsEnabled,
        "set BURLY_RUN_MIGRATION_SPIKE=1 and run this suite on its own — its v2 schema reuses v1's entity names and must not share a process with the production-shape tests"
    ),
    .serialized
)
struct MigrationSpikeTests {

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
        //
        //    Everything that container vends — the container itself, its
        //    contexts, and every model object fetched from them — is
        //    confined to the scope below and gone by the end of it. Step 4
        //    has to be a *cold* open to mean anything, and a live writer
        //    still owning the file turns "does a new container see the
        //    write?" into a question about two concurrent connections
        //    rather than about what is on disk. `autoreleasepool` is what
        //    makes that teardown deterministic rather than a matter of when
        //    the enclosing pool happens to drain: the objects underneath
        //    SwiftData are Objective-C.
        spikeMigrationTrace.withLock { $0 = SpikeMigrationTrace() }
        try autoreleasepool {
            let migrated = try openThroughSpikeLadder(.watch, at: url)
            let context = ModelContext(migrated)

            // The stage really ran, exactly once, and each half saw the
            // shape SwiftData promises it: v1 named from `willMigrate`, v2
            // from `didMigrate`. Both are only writable because each
            // version owns its model types.
            #expect(spikeMigrationTrace.withLock(\.stageRuns) == 1)
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

            // 3. The migrated store is a working v2 store, not just a
            //    readable one: write the new column, commit it, and prove
            //    the commit left the context — a second context on the same
            //    container has to see it, or the value is still only
            //    pending changes in `context`.
            set.rpe = 8.5
            try context.save()

            let sameContainer = ModelContext(migrated)
            #expect(
                try sameContainer.fetch(
                    FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()
                ).first?.rpe == 8.5
            )
        }

        // 4. Cold open: new container, new coordinator, same file, nothing
        //    left alive from step 3. This is the durability claim.
        try autoreleasepool {
            let reopened = ModelContext(try openThroughSpikeLadder(.watch, at: url))
            let reread = try #require(
                try reopened.fetch(FetchDescriptor<MigrationSpikeSchemaV2.SetRecord>()).first
            )
            #expect(reread.rpe == 8.5)
            #expect(reread.weightKg == 102.5)
        }

        // Reopening a store that is already at v2 runs no stage — the
        // migration happened once, not once per open. If this ever reads 2,
        // the store is not recording its version and a *re-run* migration,
        // not the save, is what discarded the post-migration write.
        #expect(spikeMigrationTrace.withLock(\.stageRuns) == 1)
    }
}
