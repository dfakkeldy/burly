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
        #expect(seed.exercises.count == 103)
        #expect(seed.hevyAliases.count == 103)
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

    @Test("Hevy alias lookup is case-insensitive on both sides (spec §8)")
    func hevyAliasLookupIsCaseInsensitive() throws {
        let seed = try CatalogSeed.loadBundled()
        let exactID = try #require(seed.exerciseID(forHevyAlias: "Bench Press (Barbell)"))

        #expect(seed.exerciseID(forHevyAlias: "BENCH PRESS (BARBELL)") == exactID)
        #expect(seed.exerciseID(forHevyAlias: "bench press (barbell)") == exactID)
        #expect(seed.exerciseID(forHevyAlias: "Bench PRESS (barbell)") == exactID)
        #expect(seed.exercise(forHevyAlias: "bench press (barbell)")?.name == "Barbell Bench Press")
    }

    // MARK: - m7-01 adversarial review round 1 — findings 3.1, 7.1, 7.2, 8.1

    @Test("finding 3.1 — validation rejects two aliases that collide under lookup normalization but map to different exercise IDs")
    func validationRejectsAmbiguousAliasNormalization() throws {
        let exerciseA = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000010"))
        let exerciseB = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000011"))
        let exercises = [
            CatalogSeed.CatalogExercise(id: exerciseA, name: "First", muscleGroups: [.chest]),
            CatalogSeed.CatalogExercise(id: exerciseB, name: "Second", muscleGroups: [.lats])
        ]

        // "Foo" and "FOO" normalize to the same lookup key but point at
        // different exercises — nondeterministic under plain
        // `uniquingKeysWith: { first, _ in first }` (whichever alias
        // `Dictionary` happens to iterate first would silently win).
        // Pinning regression: the old validate() never checked for this.
        #expect(throws: CatalogSeedError.ambiguousHevyAliasNormalization(normalized: "foo")) {
            try CatalogSeed(seedVersion: 1, exercises: exercises, hevyAliases: ["Foo": exerciseA, "FOO": exerciseB])
        }
    }

    @Test("finding 3.1 — two aliases that collide under normalization but agree on the same exercise ID are harmless, not rejected")
    func harmlessAliasNormalizationCollisionIsAllowed() throws {
        let exerciseID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000012"))
        let exercise = CatalogSeed.CatalogExercise(id: exerciseID, name: "Known", muscleGroups: [.core])

        let seed = try CatalogSeed(seedVersion: 1, exercises: [exercise], hevyAliases: ["Foo": exerciseID, "FOO": exerciseID])
        #expect(seed.exerciseID(forHevyAlias: "foo") == exerciseID)
    }

    @Test("finding 8.1 — an alias with surrounding whitespace still resolves via the same normalization used at lookup time")
    func aliasWithSurroundingWhitespaceStillResolves() throws {
        let exerciseID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000013"))
        let exercise = CatalogSeed.CatalogExercise(id: exerciseID, name: "Known", muscleGroups: [.core])

        // Pinning regression: seed-side normalization only lowercased
        // (never trimmed) while CSV-side lookup values are already
        // trimmed before lookup — an authored alias with stray whitespace
        // previously could never match a well-formed, trimmed CSV value.
        let seed = try CatalogSeed(seedVersion: 1, exercises: [exercise], hevyAliases: [" Known Alias ": exerciseID])
        #expect(seed.exerciseID(forHevyAlias: "Known Alias") == exerciseID)
    }

    @Test("findings 7.1/7.2 — normalizedMatchKey NFC-normalizes and locale-independently case-folds")
    func normalizedMatchKeyNormalizesAndFolds() {
        let nfc = "Caf\u{E9} Curl" // é precomposed (NFC)
        let nfd = "Cafe\u{301} Curl" // e + combining acute (NFD)
        #expect(CatalogSeed.normalizedMatchKey(nfc) == CatalogSeed.normalizedMatchKey(nfd))
        #expect(CatalogSeed.normalizedMatchKey("Straße Press") == CatalogSeed.normalizedMatchKey("STRASSE PRESS"))
        // Not diacritic-insensitive: visually/semantically distinct names
        // must not collapse onto the same key.
        #expect(CatalogSeed.normalizedMatchKey("café") != CatalogSeed.normalizedMatchKey("cafe"))
    }
}
