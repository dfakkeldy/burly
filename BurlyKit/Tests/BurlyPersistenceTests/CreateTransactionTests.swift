// SPDX-License-Identifier: GPL-3.0-or-later
// m1-06 review, M1 — a rejected create must leave nothing pending.
//
// The bug these close: `createRoutine` and `createSession` used to insert
// the parent and *then* resolve item exercise references one at a time. A
// missing exercise threw from the middle of that loop with no rollback, so
// the inserted parent and any already-inserted children stayed pending in
// the store's long-lived context. Autosave is off, but every other mutating
// method calls `save()` — so the next successful, entirely unrelated call
// would silently commit the graph the store had just rejected. Retrying the
// same UUID could also see the pending parent and report a spurious
// `.duplicateID`.
//
// Asserting "it throws" does not catch that; the old rejection test did
// exactly that and passed throughout. What catches it is the sequence the
// review specified and every test here follows: **catch the rejection, then
// perform an unrelated successful save, then cold-reopen and prove the
// rejected rows do not exist.** The unrelated save is the load-bearing step.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@MainActor
@Suite("m1-06 M1 — rejected creates leave no pending rows")
struct CreateTransactionTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    @Test("a routine rejected for a dangling exercise is absent after an unrelated save and a cold reopen")
    func rejectedRoutineIsNotCommittedByALaterSave() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let ghostID = UUID()
        let real = Fixture.exercise(name: "Bench Press")
        let survivor = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        // Two items: the first resolves, the second does not. The old code
        // inserted the Routine *and* the first RoutineItem before throwing.
        let broken = RoutineData(
            name: "Half-resolvable",
            orderIndex: 0,
            items: [
                RoutineItemData(exerciseID: real.id, order: 0),
                RoutineItemData(exerciseID: ghostID, order: 1)
            ],
            updatedAt: Fixture.epoch
        )

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
            try store.createExercise(real)

            #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
                try store.createRoutine(broken)
            }
            #expect(try store.routine(id: broken.id) == nil)

            // The step that used to commit the rejected graph.
            try store.createExercise(survivor)
        }

        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)
        #expect(try reopened.exercise(id: survivor.id) == survivor)
        #expect(try reopened.routine(id: broken.id) == nil)
        #expect(try rowCount(Routine.self, in: container) == 0)
        #expect(try rowCount(RoutineItem.self, in: container) == 0)
    }

    @Test("the rejected routine's UUID is free: retrying it after the exercise exists succeeds, with no spurious duplicateID")
    func rejectedRoutineIDCanBeRetried() throws {
        let store = try makeStore()
        let latecomer = Fixture.exercise(name: "Machine Press")
        let routine = Fixture.routine(over: [latecomer])

        #expect(throws: BurlyStoreError.missingExercise(latecomer.id)) {
            try store.createRoutine(routine)
        }

        try store.createExercise(latecomer)
        try store.createRoutine(routine)

        #expect(try store.routine(id: routine.id) == routine)
        #expect(try store.routines(includingArchived: false).map(\.id) == [routine.id])
    }

    @Test("a session rejected for a dangling exercise is absent after an unrelated save and a cold reopen, children included")
    func rejectedSessionIsNotCommittedByALaterSave() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let ghostID = UUID()
        let real = Fixture.exercise(name: "Bench Press")
        let survivor = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        // The first item carries a logged set, so the old code inserted a
        // Session, a SessionItem, and a SetRecord before throwing.
        let broken = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(
                    exerciseID: real.id,
                    order: 0,
                    sets: [
                        SetRecordData(
                            order: 0, weight: Weight(kg: 60), reps: 8, completedAt: Fixture.epoch
                        )
                    ]
                ),
                SessionItemData(exerciseID: ghostID, order: 1)
            ]
        )

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
            try store.createExercise(real)

            #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
                try store.createSession(broken)
            }
            #expect(try store.session(id: broken.id) == nil)

            try store.createExercise(survivor)
        }

        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)
        #expect(try reopened.exercise(id: survivor.id) == survivor)
        #expect(try reopened.session(id: broken.id) == nil)
        #expect(try rowCount(Session.self, in: container) == 0)
        #expect(try rowCount(SessionItem.self, in: container) == 0)
        #expect(try rowCount(SetRecord.self, in: container) == 0)
        #expect(try reopened.sessions().isEmpty)
    }

    @Test("the rejected session's UUID is free: retrying it after the exercise exists succeeds")
    func rejectedSessionIDCanBeRetried() throws {
        let store = try makeStore()
        let latecomer = Fixture.exercise(name: "Machine Press")
        let routine = Fixture.routine(over: [latecomer])
        let session = Fixture.session(from: routine)

        #expect(throws: BurlyStoreError.missingExercise(latecomer.id)) {
            try store.createSession(session)
        }

        try store.createExercise(latecomer)
        try store.createSession(session)

        #expect(try store.session(id: session.id) == session)
    }

    @Test("a duplicate id *inside* one payload is rejected before anything is inserted")
    func duplicateIDsWithinOnePayloadAreRejected() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        let repeatedItemID = UUID()
        let routine = RoutineData(
            name: "Doubled",
            orderIndex: 0,
            items: [
                RoutineItemData(id: repeatedItemID, exerciseID: bench.id, order: 0),
                RoutineItemData(id: repeatedItemID, exerciseID: bench.id, order: 1)
            ],
            updatedAt: Fixture.epoch
        )
        #expect(throws: BurlyStoreError.duplicateID(repeatedItemID)) {
            try store.createRoutine(routine)
        }
        #expect(try store.routine(id: routine.id) == nil)

        let repeatedSetID = UUID()
        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(
                    exerciseID: bench.id,
                    order: 0,
                    sets: [
                        SetRecordData(
                            id: repeatedSetID, order: 0, weight: Weight(kg: 60), reps: 8,
                            completedAt: Fixture.epoch
                        ),
                        SetRecordData(
                            id: repeatedSetID, order: 1, weight: Weight(kg: 65), reps: 6,
                            completedAt: Fixture.epoch
                        )
                    ]
                )
            ]
        )
        #expect(throws: BurlyStoreError.duplicateID(repeatedSetID)) {
            try store.createSession(session)
        }
        #expect(try store.session(id: session.id) == nil)
    }

    @Test("a child id already owned by a stored parent is rejected rather than merged away by SwiftData's unique attribute")
    func childIDOwnedElsewhereIsRejected() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let first = Fixture.routine(name: "Push A", over: [bench])
        try store.createRoutine(first)
        let takenItemID = try #require(first.items.first?.id)

        let second = RoutineData(
            name: "Push B",
            orderIndex: 1,
            items: [RoutineItemData(id: takenItemID, exerciseID: bench.id, order: 0)],
            updatedAt: Fixture.epoch
        )
        #expect(throws: BurlyStoreError.duplicateID(takenItemID)) {
            try store.createRoutine(second)
        }

        // `id` is `@Attribute(.unique)`, and SwiftData resolves a duplicate
        // insert by merging rather than failing — so without the preflight
        // the second routine would have quietly taken the first one's item.
        #expect(try store.routine(id: second.id) == nil)
        #expect(try store.routine(id: first.id) == first)
    }

    @Test("updateRoutine's rejection path has the same property: an unrelated save afterwards cannot commit the abandoned edit")
    func rejectedUpdateLeavesNoResidueEither() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let survivor = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench])
        let ghostID = UUID()

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
            try store.createExercise(bench)
            try store.createRoutine(routine)

            var broken = routine
            broken.name = "Should not stick"
            broken.items = [RoutineItemData(exerciseID: ghostID, order: 0)]
            #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
                try store.updateRoutine(broken)
            }

            try store.createExercise(survivor)
        }

        let container = try BurlyContainer.make(.phone, at: .file(url))
        let reopened = SwiftDataStore(container: container)
        #expect(try reopened.routine(id: routine.id) == routine)
        #expect(try rowCount(RoutineItem.self, in: container) == 1)
    }
}
