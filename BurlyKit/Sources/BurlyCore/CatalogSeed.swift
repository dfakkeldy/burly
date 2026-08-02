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
//
// KNOWN ALIAS TO RE-VERIFY (task m7-03): "Pullover (Cable)" maps to
// Straight-Arm Pulldown below. That pairing was a judgment call made
// without a real Hevy export in hand (m7-01, 2026-08-01) - Hevy may export
// cable pullovers as a distinct movement. Left as-is pending m7-03's
// comparison against Dan's actual export; correcting it later is a
// seedVersion bump (additive-only rule above), not an in-place edit.
//
// CASE SENSITIVITY (spec section 8): exerciseID(forHevyAlias:) and
// exercise(forHevyAlias:) match case-insensitively - a Hevy export's exact
// capitalization of an exercise title is not something Burly controls or
// can rely on. `normalizedHevyAliases` below is a lowercased mirror of
// `hevyAliases`, built once at construction, so every lookup normalizes
// both sides without re-lowercasing the whole table per call.

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

    /// Lowercased mirror of `hevyAliases`, computed once here rather than
    /// per lookup (see file doc, "CASE SENSITIVITY"). If two authored
    /// aliases ever collided case-insensitively, the first one encountered
    /// wins rather than crashing — `hevyAliases` itself has no such
    /// collision today (enforced only informally; there is 103-for-103
    /// alias/exercise parity as of seedVersion 1), but a lookup table must
    /// never trap on data that `validate()` doesn't itself reject.
    private let normalizedHevyAliases: [String: UUID]

    public init(
        seedVersion: Int,
        exercises: [CatalogExercise],
        hevyAliases: [String: UUID]
    ) throws {
        self.seedVersion = seedVersion
        self.exercises = exercises
        self.hevyAliases = hevyAliases
        self.normalizedHevyAliases = Dictionary(
            hevyAliases.map { (key, value) in (key.lowercased(), value) },
            uniquingKeysWith: { first, _ in first }
        )
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

    /// Case-insensitive lookup (spec §8): normalizes `alias` the same way
    /// `normalizedHevyAliases` was built, so callers never need to worry
    /// about matching a Hevy export's exact capitalization.
    public func exerciseID(forHevyAlias alias: String) -> UUID? {
        normalizedHevyAliases[alias.lowercased()]
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
