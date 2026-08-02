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

    /// A **finished** session shaped like the routine it came from: one
    /// item per routine item, empty sets, ready for `createSession`.
    ///
    /// `state` defaults to `.logged`, not to `SessionData`'s own `.active`
    /// default (m1-06 review round D). `createSession` refuses `.active`
    /// now — an in-flight session is a graph *plus* a journal, and only
    /// `saveActiveSession` writes both — so the fixture every "store the
    /// history and assert on it" test reaches for defaults to the state
    /// those tests actually mean. A test that wants a live session wants
    /// `Fixture.activeSession(from:)` below.
    static func session(
        id: UUID = UUID(),
        from routine: RoutineData,
        startedAt: Date = epoch,
        state: SessionState = .logged
    ) -> SessionData {
        SessionData(
            id: id,
            routineID: routine.id,
            routineName: routine.name,
            startedAt: startedAt,
            state: state,
            origin: .live,
            items: routine.items.map { item in
                SessionItemData(exerciseID: item.exerciseID, order: item.order)
            }
        )
    }

    /// The §2 Start product for `routine`, exactly as the watch builds it —
    /// graph plus plan scaffolding, ready for `saveActiveSession`, which is
    /// the only path an `.active` session can enter the store through.
    ///
    /// `id` re-stamps the session's own id for the handful of tests that
    /// need a known one; `SessionData.id` is `let`, so it is rebuilt rather
    /// than assigned. Item ids stay as `SessionBuilder` minted them.
    static func activeSession(
        id: UUID? = nil,
        from routine: RoutineData,
        startedAt: Date = epoch
    ) -> ActiveSession {
        let built = SessionBuilder.session(from: routine, clock: TestClock(startedAt))
        guard let id else { return built }
        let original = built.session
        return ActiveSession(
            session: SessionData(
                id: id,
                routineID: original.routineID,
                routineName: original.routineName,
                startedAt: original.startedAt,
                endedAt: original.endedAt,
                state: original.state,
                revision: original.revision,
                healthKitWorkoutID: original.healthKitWorkoutID,
                origin: original.origin,
                items: original.items,
                notes: original.notes
            ),
            plans: built.plans,
            restTimer: built.restTimer
        )
    }
}

extension SessionData {
    /// Returns a copy with `set` appended to the item named by `itemID`.
    ///
    /// Tests used to reach for `store.logSet(_:toSessionItem:)` to give a
    /// stored session some sets. That method is gone (m1-06 review round D
    /// — see BurlyStore.swift's "There is no `logSet`"), and its absence is
    /// the point: an active session's only write path is
    /// `saveActiveSession`. A test that just needs *finished* history with
    /// sets in it builds the sets into the DTO and creates the session
    /// whole, which is what a Hevy import or an arriving §5 `session`
    /// payload does anyway.
    func addingSet(_ set: SetRecordData, toItem itemID: UUID) -> SessionData {
        var copy = self
        guard let index = copy.items.firstIndex(where: { $0.id == itemID }) else { return copy }
        copy.items[index].sets.append(set)
        return copy
    }
}

/// A store clock the test drives. `now` is a `var` so a test can prove the
/// difference between "the store stamped its own time" and "the store
/// copied the DTO's" by moving time between calls.
///
/// `@unchecked Sendable` because `WallClock` requires `Sendable` (the
/// BurlyCore engines that hold one are value types that cross isolation
/// boundaries) and this one is a reference type with mutable state. Tests
/// drive it from a single task; nothing here escapes.
final class TestClock: WallClock, @unchecked Sendable {
    var now: Date

    init(_ now: Date = Fixture.epoch) {
        self.now = now
    }

    /// Moves the clock forward and returns the new instant.
    @discardableResult
    func advance(by interval: TimeInterval) -> Date {
        now = now.addingTimeInterval(interval)
        return now
    }
}

/// Fresh in-memory store per test. In-memory containers are isolated per
/// `ModelContainer`, so tests never see each other's rows.
///
/// The clock defaults to a `TestClock` pinned at `Fixture.epoch`: the
/// store owns `Routine.updatedAt` on the local-authoring paths (m1-06
/// review, m2), so without a fixed clock every `RoutineData` equality
/// assertion in this target would compare a fixture timestamp against
/// wall-clock now. Pass a clock explicitly when the test is *about* time.
func makeStore(
    _ kind: BurlyStoreKind = .phone,
    clock: any WallClock = TestClock()
) throws -> SwiftDataStore {
    try SwiftDataStore(kind: kind, at: .inMemory, clock: clock)
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
