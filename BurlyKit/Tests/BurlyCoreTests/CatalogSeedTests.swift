// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BurlyCore

@Suite("§9 — catalog seed resource and validation")
struct CatalogSeedTests {
    @Test("bundled JSON parses as one versioned catalog plus alias payload")
    func bundledSeedParsesAsVersionedCatalogAndAliasPayload() throws {
        let seed = try CatalogSeed.loadBundled()

        #expect(seed.seedVersion == 1)
        #expect(seed.exercises.count == 100)
        #expect(seed.hevyAliases.count == 100)
        #expect(Set(seed.exercises.map(\.id)).count == seed.exercises.count)
        #expect(Set(seed.exercises.map(\.name)).count == seed.exercises.count)
    }

    @Test("bundled exercises cover every frozen muscle group at least eight times")
    func bundledSeedCoversEveryMuscleGroup() throws {
        let seed = try CatalogSeed.loadBundled()
        let coverage = seed.exercises.reduce(into: [MuscleGroup: Int]()) { counts, exercise in
            for group in exercise.muscleGroups {
                counts[group, default: 0] += 1
            }
        }

        #expect(Set(coverage.keys) == Set(MuscleGroup.allCases))
        #expect(coverage.values.allSatisfy { $0 >= 8 })
    }

    @Test("validation rejects duplicate exercise UUIDs")
    func validationRejectsDuplicateExerciseIDs() throws {
        let id = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000001"))
        let exercises = [
            CatalogSeed.CatalogExercise(id: id, name: "First", muscleGroups: [.chest]),
            CatalogSeed.CatalogExercise(id: id, name: "Second", muscleGroups: [.lats])
        ]

        #expect(throws: CatalogSeedError.duplicateExerciseID(id)) {
            try CatalogSeed(seedVersion: 1, exercises: exercises, hevyAliases: [:])
        }
    }

    @Test("validation rejects duplicate exercise names")
    func validationRejectsDuplicateExerciseNames() throws {
        let firstID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000002"))
        let secondID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000003"))
        let exercises = [
            CatalogSeed.CatalogExercise(id: firstID, name: "Duplicate", muscleGroups: [.chest]),
            CatalogSeed.CatalogExercise(id: secondID, name: "Duplicate", muscleGroups: [.lats])
        ]

        #expect(throws: CatalogSeedError.duplicateExerciseName("Duplicate")) {
            try CatalogSeed(seedVersion: 1, exercises: exercises, hevyAliases: [:])
        }
    }

    @Test("validation rejects an exercise with no muscle tags")
    func validationRejectsEmptyMuscleGroups() throws {
        let id = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000004"))
        let exercise = CatalogSeed.CatalogExercise(id: id, name: "Untagged", muscleGroups: [])

        #expect(throws: CatalogSeedError.emptyMuscleGroups(id)) {
            try CatalogSeed(seedVersion: 1, exercises: [exercise], hevyAliases: [:])
        }
    }

    @Test("validation rejects a Hevy alias whose UUID is absent from the catalog")
    func validationRejectsUnresolvedHevyAliases() throws {
        let exerciseID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000005"))
        let missingID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000006"))
        let exercise = CatalogSeed.CatalogExercise(
            id: exerciseID,
            name: "Known",
            muscleGroups: [.core]
        )

        #expect(
            throws: CatalogSeedError.unresolvedHevyAlias(
                alias: "Unknown (Barbell)",
                exerciseID: missingID
            )
        ) {
            try CatalogSeed(
                seedVersion: 1,
                exercises: [exercise],
                hevyAliases: ["Unknown (Barbell)": missingID]
            )
        }
    }

    @Test("every Hevy alias resolves, including realistic parenthesized export names")
    func everyHevyAliasResolvesWithRealisticSpotChecks() throws {
        let seed = try CatalogSeed.loadBundled()
        let exerciseIDs = Set(seed.exercises.map(\.id))

        #expect(seed.hevyAliases.values.allSatisfy(exerciseIDs.contains))
        #expect(seed.exercise(forHevyAlias: "Bench Press (Barbell)")?.name == "Barbell Bench Press")
        #expect(seed.exercise(forHevyAlias: "Squat (Barbell)")?.name == "Back Squat")
        #expect(seed.exercise(forHevyAlias: "Deadlift (Barbell)")?.name == "Conventional Deadlift")
    }
}
