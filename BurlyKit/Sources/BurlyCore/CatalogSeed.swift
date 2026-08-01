// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — versioned, authored exercise catalog seed (spec §9).
//
// The bundled JSON is Burly-owned source material: exercise names and muscle
// tags were hand-curated from general lifting knowledge, not copied from a
// third-party catalog. JSON is intentionally kept outside executable Swift so
// catalog and Hevy-alias changes remain easy to review as authored data.
//
// MUTABILITY: catalog-seed-v1.json content (exercise names, muscle tags,
// Hevy aliases) is mutable in place ONLY until the first TestFlight build
// ships. Before that point nobody has installed seedVersion 1, so editing an
// existing entry in place is a correction, not a breaking change. Once a
// TestFlight build has shipped, `applyCatalogSeed` matches purely by UUID and
// deliberately never overwrites a property of an already-inserted Exercise
// (see SwiftDataStore.applyCatalogSeed) — a tester's device would keep the
// old tags forever. Any further content change after that point must ship as
// a new seedVersion (additive rows only; never mutate a shipped id's name or
// muscleGroups in place). Existing UUIDs must never be changed or reused
// regardless of which side of this line a change falls on.

import Foundation

public struct CatalogSeed: Sendable, Equatable, Decodable {
    public struct CatalogExercise: Sendable, Equatable, Hashable, Codable, Identifiable {
        /// Permanent seed identity and wire contract.
        ///
        /// Once a catalog version ships, this UUID must never be regenerated,
        /// changed, or reassigned to a different exercise. Seed bumps match on
        /// this value so user edits can safely diverge from the authored name.
        public let id: UUID
        public let name: String
        public let muscleGroups: [MuscleGroup]

        public init(id: UUID, name: String, muscleGroups: [MuscleGroup]) {
            self.id = id
            self.name = name
            self.muscleGroups = muscleGroups
        }
    }

    public let seedVersion: Int
    public let exercises: [CatalogExercise]

    /// Alternative names emitted by Hevy exports, mapped to permanent catalog
    /// UUIDs. It versions in the same payload as the exercise catalog.
    public let hevyAliases: [String: UUID]

    public init(
        seedVersion: Int,
        exercises: [CatalogExercise],
        hevyAliases: [String: UUID]
    ) throws {
        self.seedVersion = seedVersion
        self.exercises = exercises
        self.hevyAliases = hevyAliases
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            seedVersion: container.decode(Int.self, forKey: .seedVersion),
            exercises: container.decode([CatalogExercise].self, forKey: .exercises),
            hevyAliases: container.decode([String: UUID].self, forKey: .hevyAliases)
        )
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    /// Loads the SPM-processed catalog and Hevy aliases as one versioned unit.
    public static func loadBundled() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "catalog-seed-v1",
            withExtension: "json"
        ) else {
            throw CatalogSeedError.bundledResourceNotFound
        }
        return try Self(jsonData: Data(contentsOf: url))
    }

    public func exerciseID(forHevyAlias alias: String) -> UUID? {
        hevyAliases[alias]
    }

    public func exercise(forHevyAlias alias: String) -> CatalogExercise? {
        guard let id = exerciseID(forHevyAlias: alias) else { return nil }
        return exercises.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case seedVersion
        case exercises
        case hevyAliases
    }

    private func validate() throws {
        guard seedVersion > 0 else {
            throw CatalogSeedError.invalidSeedVersion(seedVersion)
        }

        var ids = Set<UUID>()
        var names = Set<String>()
        for exercise in exercises {
            guard ids.insert(exercise.id).inserted else {
                throw CatalogSeedError.duplicateExerciseID(exercise.id)
            }
            guard exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw CatalogSeedError.emptyExerciseName(exercise.id)
            }
            guard names.insert(exercise.name).inserted else {
                throw CatalogSeedError.duplicateExerciseName(exercise.name)
            }
            guard exercise.muscleGroups.isEmpty == false else {
                throw CatalogSeedError.emptyMuscleGroups(exercise.id)
            }
            guard Set(exercise.muscleGroups).count == exercise.muscleGroups.count else {
                throw CatalogSeedError.duplicateMuscleGroup(exercise.id)
            }
        }

        for (alias, exerciseID) in hevyAliases {
            guard alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw CatalogSeedError.emptyHevyAlias
            }
            guard ids.contains(exerciseID) else {
                throw CatalogSeedError.unresolvedHevyAlias(alias: alias, exerciseID: exerciseID)
            }
        }
    }
}

public enum CatalogSeedError: Error, Sendable, Equatable {
    case bundledResourceNotFound
    case invalidSeedVersion(Int)
    case duplicateExerciseID(UUID)
    case emptyExerciseName(UUID)
    case duplicateExerciseName(String)
    case emptyMuscleGroups(UUID)
    case duplicateMuscleGroup(UUID)
    case emptyHevyAlias
    case unresolvedHevyAlias(alias: String, exerciseID: UUID)
}
