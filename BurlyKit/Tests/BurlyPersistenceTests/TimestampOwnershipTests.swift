// SPDX-License-Identifier: GPL-3.0-or-later
// m1-06 review, m2 — who owns `Routine.updatedAt`.
//
// Before this round the answer changed by operation without anything
// saying so: `updateRoutine` and `archiveRoutine` stamped the store's own
// time, while `createRoutine` persisted whatever the caller's DTO carried.
// A locally-authored routine could therefore be born backdated or
// postdated. But the fix is not "make create store-owned and be done":
// §5's `snapshot` push replicates phone-authored routines onto the watch,
// and that path legitimately *must* keep the phone's timestamp, or the two
// devices disagree about when the routine last changed. One generic create
// cannot express both rules.
//
// So there are two paths, and this suite is the contract between them:
//
// - **Local authoring** (`createRoutine`, `updateRoutine`) — the store's
//   clock wins, always; the DTO's `updatedAt` is ignored.
// - **Replicated apply** (`applyRoutineSnapshot`) — the author's timestamp
//   wins, always; the store's clock is never consulted.
//
// Both are asserted on both store kinds against an injected clock, because
// the whole point is that the *rule*, not the device, decides.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m1-06 m2 — updatedAt ownership: local authoring vs replicated apply")
struct TimestampOwnershipTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    private static let authoredAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Local authoring

    @Test("createRoutine stamps the store's clock and ignores the DTO's timestamp — on both store kinds", arguments: [BurlyStoreKind.phone, .watch])
    func createIsStoreOwned(kind: BurlyStoreKind) throws {
        let clock = TestClock()
        let store = try makeStore(kind, clock: clock)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        var routine = Fixture.routine(over: [bench])
        // Both directions of the hazard: a stale DTO cannot backdate the
        // create, and a forged one cannot postdate it.
        routine.updatedAt = .distantPast
        let createdAt = clock.advance(by: 500)
        try store.createRoutine(routine)
        #expect(try store.routine(id: routine.id)?.updatedAt == createdAt)

        var postdated = Fixture.routine(name: "Push B", orderIndex: 1, over: [bench])
        postdated.updatedAt = .distantFuture
        try store.createRoutine(postdated)
        #expect(try store.routine(id: postdated.id)?.updatedAt == createdAt)
    }

    @Test("updateRoutine stamps the store's clock too — on both store kinds", arguments: [BurlyStoreKind.phone, .watch])
    func updateIsStoreOwned(kind: BurlyStoreKind) throws {
        let clock = TestClock()
        let store = try makeStore(kind, clock: clock)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        var routine = Fixture.routine(over: [bench])
        try store.createRoutine(routine)

        routine.name = "Renamed"
        routine.updatedAt = .distantPast
        let editedAt = clock.advance(by: 900)
        try store.updateRoutine(routine)

        let reloaded = try #require(try store.routine(id: routine.id))
        #expect(reloaded.name == "Renamed")
        #expect(reloaded.updatedAt == editedAt)
    }

    // MARK: - Replicated apply

    @Test("applyRoutineSnapshot preserves the author's updatedAt and never consults the store clock — on both store kinds", arguments: [BurlyStoreKind.phone, .watch])
    func snapshotApplyPreservesTheAuthoredTimestamp(kind: BurlyStoreKind) throws {
        let clock = TestClock()
        let store = try makeStore(kind, clock: clock)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        var authored = Fixture.routine(over: [bench])
        authored.updatedAt = Self.authoredAt
        clock.advance(by: 10_000)

        // Create-by-snapshot.
        try store.applyRoutineSnapshot(authored)
        #expect(try store.routine(id: authored.id) == authored)

        // Replace-by-snapshot: a later push from the same author.
        var revised = authored
        revised.name = "Push A v2"
        revised.updatedAt = Self.authoredAt.addingTimeInterval(86_400)
        clock.advance(by: 10_000)
        try store.applyRoutineSnapshot(revised)

        let reloaded = try #require(try store.routine(id: authored.id))
        #expect(reloaded == revised)
        #expect(reloaded.updatedAt == Self.authoredAt.addingTimeInterval(86_400))
    }

    @Test("applyRoutineSnapshot replicates archive state, which updateRoutine deliberately refuses to touch")
    func snapshotApplyReplicatesArchiveState() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        var authored = Fixture.routine(over: [bench])
        authored.updatedAt = Self.authoredAt
        authored.archivedAt = Self.authoredAt.addingTimeInterval(60)
        try store.applyRoutineSnapshot(authored)
        #expect(try store.routine(id: authored.id)?.archivedAt == Self.authoredAt.addingTimeInterval(60))
        #expect(try store.routines(includingArchived: false).isEmpty)

        // The author un-archived it. A replica mirrors that; `updateRoutine`
        // would not, and must not — it is an edit, not a replication.
        var unarchived = authored
        unarchived.archivedAt = nil
        unarchived.updatedAt = Self.authoredAt.addingTimeInterval(120)
        try store.applyRoutineSnapshot(unarchived)
        #expect(try store.routine(id: authored.id)?.archivedAt == nil)
        #expect(try store.routines(includingArchived: false).map(\.id) == [authored.id])
    }

    @Test("a replacing snapshot rewrites the item list wholesale, leaving no orphan RoutineItem rows")
    func snapshotApplyReplacesItemsCleanly() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let store = SwiftDataStore(container: container, clock: TestClock())
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let curl = Fixture.exercise(name: "Curl", muscleGroups: [.biceps])
        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createExercise(curl)

        var authored = Fixture.routine(over: [bench, row])
        authored.updatedAt = Self.authoredAt
        try store.applyRoutineSnapshot(authored)
        #expect(try rowCount(RoutineItem.self, in: container) == 2)

        var revised = authored
        revised.items = [RoutineItemData(exerciseID: curl.id, order: 0)]
        revised.updatedAt = Self.authoredAt.addingTimeInterval(60)
        try store.applyRoutineSnapshot(revised)

        #expect(try store.routine(id: authored.id)?.items.map(\.exerciseID) == [curl.id])
        #expect(try rowCount(RoutineItem.self, in: container) == 1)
        #expect(try rowCount(Exercise.self, in: container) == 3)
    }

    @Test("applyRoutineSnapshot rejects a dangling exercise reference without touching the stored replica")
    func snapshotApplyRejectsDanglingReferences() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        var authored = Fixture.routine(over: [bench])
        authored.updatedAt = Self.authoredAt
        try store.applyRoutineSnapshot(authored)

        let ghostID = UUID()
        var broken = authored
        broken.name = "Should not stick"
        broken.items = [RoutineItemData(exerciseID: ghostID, order: 0)]
        broken.updatedAt = Self.authoredAt.addingTimeInterval(60)

        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.applyRoutineSnapshot(broken)
        }
        // An unrelated successful save must not commit the abandoned edit.
        try store.createExercise(Fixture.exercise(name: "Row", muscleGroups: [.upperBack]))
        #expect(try store.routine(id: authored.id) == authored)
    }

    // MARK: - The two paths side by side

    @Test("the same RoutineData through both paths produces two different stored timestamps — which is the whole point")
    func thePathsDisagreeDeliberately() throws {
        let clock = TestClock()
        let localStore = try makeStore(.phone, clock: clock)
        let replicaStore = try makeStore(.watch, clock: clock)
        let bench = Fixture.exercise(name: "Bench Press")
        try localStore.createExercise(bench)
        try replicaStore.createExercise(bench)

        var routine = Fixture.routine(over: [bench])
        routine.updatedAt = Self.authoredAt
        clock.advance(by: 4_242)

        try localStore.createRoutine(routine)
        try replicaStore.applyRoutineSnapshot(routine)

        #expect(try localStore.routine(id: routine.id)?.updatedAt == clock.now)
        #expect(try replicaStore.routine(id: routine.id)?.updatedAt == Self.authoredAt)
        #expect(clock.now != Self.authoredAt)
    }

    @Test("archiveRoutine still dates both fields from the caller's instant — one event, one timestamp")
    func archiveKeepsItsExplicitDate() throws {
        let clock = TestClock()
        let store = try makeStore(clock: clock)
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        try store.createRoutine(routine)

        let archivedAt = Fixture.epoch.addingTimeInterval(9_999)
        clock.advance(by: 1)
        try store.archiveRoutine(id: routine.id, at: archivedAt)

        let reloaded = try #require(try store.routine(id: routine.id))
        #expect(reloaded.archivedAt == archivedAt)
        #expect(reloaded.updatedAt == archivedAt)
    }
}
