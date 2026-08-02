// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — `allLoggedSetSlices()`, the one-shot, all-exercise, all-time
// bounded fetch the §5 digest generator (`BurlyPhoneSync.SessionDigestGenerator`)
// is built on. See the protocol doc for why this exists instead of a
// per-exercise loop over `loggedSetSlices(exerciseID:since:through:)`.
import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m4-04 — allLoggedSetSlices: the digest generator's one-shot fetch")
struct AllLoggedSetSlicesTests {

    @Test("returns every logged set across every exercise, and nothing from an .active session")
    func returnsEveryLoggedSetAcrossEveryExercise() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)

        var loggedEmpty = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let benchItemID = try #require(loggedEmpty.items.first { $0.exerciseID == bench.id }?.id)
        let rowItemID = try #require(loggedEmpty.items.first { $0.exerciseID == row.id }?.id)
        loggedEmpty = loggedEmpty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch),
            toItem: benchItemID
        )
        loggedEmpty = loggedEmpty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 60), reps: 10, completedAt: Fixture.epoch),
            toItem: rowItemID
        )
        try store.createSession(loggedEmpty)

        // An .active session's sets must never appear — "history" is
        // .logged only, same rule every other §7 query follows.
        var active = Fixture.activeSession(from: routine, startedAt: Fixture.epoch.addingTimeInterval(60))
        try SessionMutator.logSet(
            itemID: try #require(active.items.first { $0.exerciseID == bench.id }?.id),
            weight: Weight(kg: 999), reps: 1, in: &active, clock: TestClock()
        )
        try store.saveActiveSession(active)

        let slices = try store.allLoggedSetSlices()

        #expect(slices.count == 2)
        #expect(Set(slices.map(\.set.weight.kg)) == [100, 60])
        #expect(slices.allSatisfy { $0.sessionID == loggedEmpty.id })
        #expect(slices.allSatisfy { $0.set.weight.kg != 999 })
    }

    @Test("an empty store returns an empty array, not an error")
    func emptyStoreReturnsEmptyArray() throws {
        let store = try makeStore()
        #expect(try store.allLoggedSetSlices().isEmpty)
    }

    @Test("a set logged against an item with no exercise reference is still included, with a nil exerciseID")
    func nilExerciseReferenceIsIncludedWithNilID() throws {
        let store = try makeStore()
        let orphan = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(
                    exerciseID: nil,
                    order: 0,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 40), reps: 10, completedAt: Fixture.epoch)]
                )
            ]
        )
        try store.createSession(orphan)

        let slices = try store.allLoggedSetSlices()
        #expect(slices.count == 1)
        #expect(slices.first?.exerciseID == nil)
    }
}
