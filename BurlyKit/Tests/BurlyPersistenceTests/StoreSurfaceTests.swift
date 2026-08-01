// SPDX-License-Identifier: GPL-3.0-or-later
// m1-04 gap closure — rounding out the `BurlyStore` surface §2/§7/§9 need,
// where §1 obviously implies it:
//
// - `updateRoutine`: §6/§9's rename + reorder-items edit path. §1 gives
//   `Routine` an `orderIndex` and an `updatedAt`; nothing before this task
//   could ever change either one after `createRoutine`.
// - `sessions(state:)`: a plain state filter available on either store
//   kind, for §2's relaunch-into-Resume path (find the `.active` session)
//   and §7's stats (all `.logged` sessions) — distinct from the watch-only
//   ack framing `loggedSessionsAwaitingAck` carries.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m1-04 — updateRoutine and sessions(state:)")
struct StoreSurfaceTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    // MARK: - updateRoutine

    @Test("updateRoutine persists a rename and an orderIndex change; the STORE sets updatedAt, not the caller's DTO")
    func updateRoutineRenamesReordersAndStoreSetsUpdatedAt() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        var routine = Fixture.routine(name: "Push A", orderIndex: 0, over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        routine.name = "Push A (renamed)"
        routine.orderIndex = 2
        // A deliberately stale timestamp in the DTO — if the store trusted
        // this instead of maintaining `updatedAt` itself, the reloaded value
        // would come back stuck in the distant past.
        routine.updatedAt = .distantPast

        let before = Date()
        try store.updateRoutine(routine)
        let after = Date()

        let reloaded = try #require(try store.routine(id: routine.id))
        #expect(reloaded.name == "Push A (renamed)")
        #expect(reloaded.orderIndex == 2)
        // Proves STORE maintenance, not a pass-through of the stale DTO
        // value: the stored `updatedAt` is newer than the stale input and
        // falls within the wall-clock window the call actually ran in.
        #expect(reloaded.updatedAt > routine.updatedAt)
        #expect(reloaded.updatedAt >= before && reloaded.updatedAt <= after)
    }

    @Test("updateRoutine persists a reordered/replaced item list, disk-backed across a cold reopen")
    func updateRoutineReordersItemsAcrossColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        let routine = Fixture.routine(over: [bench, row])
        var edited = routine

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createExercise(curl)
            try store.createRoutine(routine)

            // Reverse bench/row and append curl — a swap + an add in one edit.
            edited.items = [
                RoutineItemData(exerciseID: row.id, order: 0),
                RoutineItemData(exerciseID: bench.id, order: 1),
                RoutineItemData(exerciseID: curl.id, order: 2)
            ]
            // A stale DTO timestamp, same rationale as the in-memory test
            // above: the store must not carry this through to disk.
            edited.updatedAt = .distantPast
            try store.updateRoutine(edited)
        }

        let reopened = try SwiftDataStore(kind: .phone, at: .file(url))
        let reloaded = try #require(try reopened.routine(id: routine.id))
        #expect(reloaded.items.map(\.exerciseID) == [row.id, bench.id, curl.id])
        #expect(reloaded.items.map(\.order) == [0, 1, 2])
        // The store-maintained `updatedAt` survives the cold reopen and is
        // not the stale value the DTO carried.
        #expect(reloaded.updatedAt > .distantPast)

        // The old RoutineItem rows were genuinely replaced, not merely
        // appended to — three items in, three items out, no leftovers.
        let container = try BurlyContainer.make(.phone, at: .file(url))
        #expect(try rowCount(RoutineItem.self, in: container) == 3)
        // All three exercises — including the two dropped from the old
        // item list's positions — remain untouched rows.
        #expect(try rowCount(Exercise.self, in: container) == 3)
    }

    @Test("updateRoutine on an unknown id throws notFound and writes nothing")
    func updateRoutineOnUnknownIDThrowsNotFound() throws {
        let store = try makeStore()
        let ghost = RoutineData(name: "Ghost", orderIndex: 0, updatedAt: Fixture.epoch)

        #expect(throws: BurlyStoreError.notFound(ghost.id)) {
            try store.updateRoutine(ghost)
        }
        #expect(try store.routine(id: ghost.id) == nil)
    }

    @Test("updateRoutine rejects a dangling exercise reference and leaves the stored routine untouched")
    func updateRoutineRejectsDanglingReferenceWithoutMutating() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let ghostID = UUID()
        var broken = routine
        broken.name = "Should not stick"
        broken.items = [RoutineItemData(exerciseID: ghostID, order: 0)]

        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.updateRoutine(broken)
        }

        // Rejected before any row was touched: the original name and item
        // survive exactly as they were.
        let survivor = try #require(try store.routine(id: routine.id))
        #expect(survivor == routine)
    }

    @Test("updateRoutine never touches archivedAt — an edit cannot un-archive or archive as a side effect")
    func updateRoutineDoesNotTouchArchiveState() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)
        try store.archiveRoutine(id: routine.id, at: Fixture.epoch.addingTimeInterval(60))

        var edited = try #require(try store.routine(id: routine.id))
        edited.name = "Renamed while archived"
        // Even an explicit nil in the payload must not un-archive: the
        // store ignores `archivedAt` on this path entirely.
        edited.archivedAt = nil
        try store.updateRoutine(edited)

        let reloaded = try #require(try store.routine(id: routine.id))
        #expect(reloaded.name == "Renamed while archived")
        #expect(reloaded.archivedAt == Fixture.epoch.addingTimeInterval(60))
    }

    // MARK: - sessions(state:)

    @Test("sessions(state:) filters to the requested state, reverse-chronological")
    func sessionsFilterByStateReverseChronological() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let active = Fixture.session(from: routine, startedAt: Fixture.epoch)
        var olderLogged = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        olderLogged.state = .logged
        var newerLogged = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(120))
        newerLogged.state = .logged
        try store.createSession(active)
        try store.createSession(olderLogged)
        try store.createSession(newerLogged)

        #expect(try store.sessions(state: .active).map(\.id) == [active.id])
        #expect(try store.sessions(state: .logged).map(\.id) == [newerLogged.id, olderLogged.id])
    }

    @Test("sessions(state:) works on a watch-kind store — it carries no ack framing, unlike loggedSessionsAwaitingAck")
    func sessionsFilterByStateWorksOnWatchStore() throws {
        let store = try makeStore(.watch)
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let active = Fixture.session(from: routine)
        try store.createSession(active)

        #expect(try store.sessions(state: .active).map(\.id) == [active.id])
        #expect(try store.sessions(state: .logged).isEmpty)
    }

    @Test("sessions(state:) returns an empty array, not an error, when nothing matches")
    func sessionsFilterByStateEmptyIsNotAnError() throws {
        let store = try makeStore()
        #expect(try store.sessions(state: .logged).isEmpty)
        #expect(try store.sessions(state: .active).isEmpty)
    }
}
