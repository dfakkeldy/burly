// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§9 #1 — idempotent, additive catalog seed loader")
struct SeedLoaderTests {
    @Test("fresh load inserts the complete catalog as active curated exercises")
    func freshLoadInsertsCompleteCuratedCatalog() throws {
        let store = try makeStore()
        let seed = try CatalogSeed.loadBundled()

        let inserted = try SeedLoader.apply(seed, to: store)
        let stored = try store.exercises(includingArchived: true)

        #expect(inserted == seed.exercises.count)
        #expect(stored.count == seed.exercises.count)
        #expect(stored.allSatisfy { $0.origin == .curated })
        #expect(stored.allSatisfy { $0.needsNaming == false })
        #expect(stored.allSatisfy { $0.archivedAt == nil })
    }

    @Test("applying the same seed version twice is a no-op with no duplicates")
    func sameVersionReapplyIsNoOp() throws {
        let store = try makeStore()
        let seed = try CatalogSeed.loadBundled()

        let firstInserted = try SeedLoader.apply(seed, to: store)
        let secondInserted = try SeedLoader.apply(seed, to: store)

        #expect(firstInserted == seed.exercises.count)
        #expect(secondInserted == 0)
        #expect(try store.exercises(includingArchived: true).count == seed.exercises.count)
    }

    @Test("applying an older seed version after a newer one is stored is a no-op")
    func olderSeedVersionAfterNewerStoredIsNoOp() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let seed = try CatalogSeed.loadBundled()
        try SeedLoader.apply(seed, to: SwiftDataStore(container: container))

        let bumped = try makeBumpedSeed(from: seed)
        let bumpedInserted = try SeedLoader.apply(bumped, to: SwiftDataStore(container: container))
        #expect(bumpedInserted == 1)

        // seed.seedVersion is now older than what's stored (bumped). Reapplying
        // it must not insert, delete, or downgrade the stored version.
        let olderReapplyInserted = try SeedLoader.apply(seed, to: SwiftDataStore(container: container))
        #expect(olderReapplyInserted == 0)

        let verifier = SwiftDataStore(container: container)
        #expect(try verifier.exercises(includingArchived: true).count == bumped.exercises.count)

        let metadataContext = ModelContext(container)
        let states = try metadataContext.fetch(FetchDescriptor<CatalogSeedState>())
        let state = try #require(states.first)
        #expect(states.count == 1)
        #expect(state.version == bumped.seedVersion)
    }

    @Test("applying the same seed version with different content is a no-op before any fetch or insert")
    func sameSeedVersionWithDifferentContentIsNoOp() throws {
        let store = try makeStore()
        let seed = try CatalogSeed.loadBundled()
        try SeedLoader.apply(seed, to: store)

        // Same seedVersion as what's already stored, but with an extra
        // exercise the store has never seen. The version guard is a pure
        // integer comparison — it must fire before the loader ever fetches
        // existing exercises or considers this new UUID for insertion.
        let differentContentSameVersion = try CatalogSeed(
            seedVersion: seed.seedVersion,
            exercises: seed.exercises + [
                CatalogSeed.CatalogExercise(
                    id: try bumpExerciseID(),
                    name: "Should Never Be Inserted",
                    muscleGroups: [.core]
                )
            ],
            hevyAliases: seed.hevyAliases
        )

        let inserted = try SeedLoader.apply(differentContentSameVersion, to: store)
        #expect(inserted == 0)

        let stored = try store.exercises(includingArchived: true)
        #expect(stored.count == seed.exercises.count)
        #expect(stored.contains { $0.name == "Should Never Be Inserted" } == false)
    }

    @Test("a higher seed version inserts only newly introduced UUIDs")
    func seedBumpAddsOnlyNewExercises() throws {
        let store = try makeStore()
        let seed = try CatalogSeed.loadBundled()
        try SeedLoader.apply(seed, to: store)

        let custom = ExerciseData(
            name: "My Garage Lift",
            muscleGroups: [.core],
            origin: .custom
        )
        try store.createExercise(custom)

        let bumped = try makeBumpedSeed(from: seed)
        let bumpExerciseID = try bumpExerciseID()
        let inserted = try SeedLoader.apply(bumped, to: store)
        let all = try store.exercises(includingArchived: true)

        #expect(inserted == 1)
        #expect(all.count == seed.exercises.count + 2)
        #expect(try store.exercise(id: custom.id) == custom)
        #expect(try store.exercise(id: bumpExerciseID)?.name == "Belt Squat")
        #expect(try store.exercise(id: bumpExerciseID)?.origin == .curated)
    }

    @Test("a seed bump preserves a user's rename and archive timestamp")
    func seedBumpPreservesUserRenameAndArchive() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let seed = try CatalogSeed.loadBundled()
        try SeedLoader.apply(seed, to: SwiftDataStore(container: container))

        let benchID = try #require(seed.exerciseID(forHevyAlias: "Bench Press (Barbell)"))
        let archivedAt = Date(timeIntervalSince1970: 1_780_123_456)
        do {
            let editingContext = ModelContext(container)
            var descriptor = FetchDescriptor<Exercise>(
                predicate: #Predicate { $0.id == benchID }
            )
            descriptor.fetchLimit = 1
            let bench = try #require(try editingContext.fetch(descriptor).first)
            bench.name = "My Competition Bench"
            bench.archivedAt = archivedAt
            try editingContext.save()
        }

        let bumped = try makeBumpedSeed(from: seed)
        try SeedLoader.apply(bumped, to: SwiftDataStore(container: container))

        let verifier = SwiftDataStore(container: container)
        let preserved = try #require(try verifier.exercise(id: benchID))
        #expect(preserved.name == "My Competition Bench")
        #expect(preserved.archivedAt == archivedAt)
        #expect(preserved.origin == .curated)
    }

    @Test("applied seed version survives a cold launch and prevents reinsertion")
    func appliedVersionSurvivesColdLaunch() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let seed = try CatalogSeed.loadBundled()

        do {
            let firstLaunch = try SwiftDataStore(kind: .phone, at: .file(url))
            #expect(try SeedLoader.apply(seed, to: firstLaunch) == seed.exercises.count)
        }

        let secondContainer = try BurlyContainer.phone(at: .file(url))
        let metadataContext = ModelContext(secondContainer)
        let states = try metadataContext.fetch(FetchDescriptor<CatalogSeedState>())
        let state = try #require(states.first)
        #expect(states.count == 1)
        #expect(state.key == CatalogSeedState.exerciseCatalogKey)
        #expect(state.version == seed.seedVersion)

        let secondLaunch = SwiftDataStore(container: secondContainer)
        #expect(try SeedLoader.apply(seed, to: secondLaunch) == 0)
        #expect(try secondLaunch.exercises(includingArchived: true).count == seed.exercises.count)
    }

    private func makeBumpedSeed(from seed: CatalogSeed) throws -> CatalogSeed {
        let bumpExerciseID = try bumpExerciseID()
        let addition = CatalogSeed.CatalogExercise(
            id: bumpExerciseID,
            name: "Belt Squat",
            muscleGroups: [.quads, .glutes]
        )
        var aliases = seed.hevyAliases
        aliases["Belt Squat (Machine)"] = bumpExerciseID
        return try CatalogSeed(
            seedVersion: seed.seedVersion + 1,
            exercises: seed.exercises + [addition],
            hevyAliases: aliases
        )
    }

    private func bumpExerciseID() throws -> UUID {
        // One past the real catalog's highest sequential id (currently .103,
        // Trap Bar Deadlift) so this synthetic bump addition never collides
        // with a real seed entry.
        try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000104"))
    }
}
