// SPDX-License-Identifier: GPL-3.0-or-later
// Shared fixtures for the BurlyPersistence acceptance tests.

import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

enum Fixture {
    /// A fixed instant so every assertion compares exact `Date` values —
    /// round-trip identity (§1 acceptance #1) is meaningless against `now`.
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func exercise(
        id: UUID = UUID(),
        name: String,
        muscleGroups: [MuscleGroup] = [.chest, .triceps],
        origin: ExerciseOrigin = .curated
    ) -> ExerciseData {
        ExerciseData(id: id, name: name, muscleGroups: muscleGroups, origin: origin)
    }

    /// A routine whose items point at `exercises`, in the order given.
    static func routine(
        id: UUID = UUID(),
        name: String = "Push A",
        orderIndex: Int = 0,
        over exercises: [ExerciseData]
    ) -> RoutineData {
        RoutineData(
            id: id,
            name: name,
            orderIndex: orderIndex,
            items: exercises.enumerated().map { index, exercise in
                RoutineItemData(
                    exerciseID: exercise.id,
                    order: index,
                    defaultSetCount: 3,
                    restOverride: index == 0 ? 120 : nil,
                    note: index == 0 ? "top set first" : nil
                )
            },
            updatedAt: epoch
        )
    }

    /// The §2 "start" step in miniature: a session as a mutable copy of the
    /// routine, with empty sets, ready for `logSet`. The real copy lives in
    /// BurlyCore (§2 acceptance #1) — this is only enough to exercise
    /// the store.
    static func session(
        id: UUID = UUID(),
        from routine: RoutineData,
        startedAt: Date = epoch
    ) -> SessionData {
        SessionData(
            id: id,
            routineID: routine.id,
            routineName: routine.name,
            startedAt: startedAt,
            origin: .live,
            items: routine.items.map { item in
                SessionItemData(exerciseID: item.exerciseID, order: item.order)
            }
        )
    }
}

/// Fresh in-memory store per test. In-memory containers are isolated per
/// `ModelContainer`, so tests never see each other's rows.
func makeStore(_ kind: BurlyStoreKind = .phone) throws -> SwiftDataStore {
    try SwiftDataStore(kind: kind, at: .inMemory)
}

/// A unique temp file URL for the cold-reload test, cleaned up by the caller.
func makeTemporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "burly-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "Burly.store", directoryHint: .notDirectory)
}

func removeStoreFiles(at url: URL) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: directory)
}
