// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #1, second half: "add/remove/skip/swap/reorder
// mutations preserve set data and ordering invariants."
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 Mid-session edits — SessionMutator")
struct SessionMutatorTests {
    /// A started session with one set already logged on each of the three
    /// exercises, so every mutation below has real data to preserve.
    private func startedSession(
        ids: SequentialIDs = SequentialIDs(),
        clock: ManualClock = ManualClock()
    ) throws -> (session: ActiveSession, ids: SequentialIDs, clock: ManualClock) {
        var active = SessionBuilder.session(from: Fixture.routine(ids: ids), clock: clock, makeID: ids.make)
        for (index, item) in active.items.enumerated() {
            try SessionMutator.logSet(
                itemID: item.id,
                weight: Weight(kg: Double(40 + index * 10)),
                reps: 8 + index,
                in: &active,
                clock: clock,
                makeID: ids.make
            )
            clock.advance(60)
        }
        return (active, ids, clock)
    }

    // MARK: - Add / remove set

    @Test("add set adds one empty slot and touches nothing else")
    func addSetAddsSlot() throws {
        var active = try startedSession().session
        let itemID = active.items[0].id
        let before = active

        try SessionMutator.addSet(toItem: itemID, in: &active)

        #expect(active.plannedSetCount(itemID) == before.plannedSetCount(itemID) + 1)
        #expect(active.allSets == before.allSets)
        #expect(active.items.map(\.id) == before.items.map(\.id))
        #expect(active.isWellFormed)
    }

    @Test("remove empty set removes a slot, never a logged set")
    func removeEmptySetRemovesSlot() throws {
        var active = try startedSession().session
        let itemID = active.items[0].id   // 3 planned, 1 logged
        let before = active

        try SessionMutator.removeEmptySet(fromItem: itemID, in: &active)

        #expect(active.plannedSetCount(itemID) == 2)
        #expect(active.allSets == before.allSets)
        #expect(active.isWellFormed)
    }

    @Test("remove empty set is refused when every slot holds a logged set")
    func removeEmptySetRefusedWhenFull() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let itemID = active.items[2].id   // 2 planned, 1 logged
        try SessionMutator.logSet(
            itemID: itemID, weight: Weight(kg: 20), reps: 10,
            in: &active, clock: clock, makeID: ids.make
        )
        #expect(active.hasEmptySetSlot(itemID) == false)

        #expect(throws: SessionMutationError.noEmptySetSlot(itemID: itemID)) {
            try SessionMutator.removeEmptySet(fromItem: itemID, in: &active)
        }
        #expect(active.loggedSetCount(itemID) == 2)
    }

    @Test("remove empty set is refused for the last remaining slot — that is skip, not remove")
    func removeEmptySetRefusedForLastSlot() throws {
        let ids = SequentialIDs()
        var active = SessionBuilder.session(
            from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
            clock: ManualClock(),
            makeID: ids.make
        )
        let itemID = active.items[0].id

        #expect(throws: SessionMutationError.cannotRemoveLastSetSlot(itemID: itemID)) {
            try SessionMutator.removeEmptySet(fromItem: itemID, in: &active)
        }
        #expect(active.plannedSetCount(itemID) == 1)
    }

    // MARK: - Logging

    @Test("logSet stamps completedAt from the injected clock and appends in dense set order")
    func logSetUsesInjectedClock() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var active = SessionBuilder.session(from: Fixture.routine(ids: ids), clock: clock, makeID: ids.make)
        let itemID = active.items[0].id

        clock.advance(120)
        let first = try SessionMutator.logSet(
            itemID: itemID, weight: Weight(kg: 60), reps: 8,
            in: &active, clock: clock, makeID: ids.make
        )
        clock.advance(95)
        let second = try SessionMutator.logSet(
            itemID: itemID, weight: Weight(kg: 62.5), reps: 6,
            in: &active, clock: clock, makeID: ids.make
        )

        #expect(first.completedAt == active.session.startedAt.addingTimeInterval(120))
        #expect(second.completedAt == active.session.startedAt.addingTimeInterval(215))
        #expect(active.item(itemID)?.sets.map(\.order) == [0, 1])
        #expect(active.item(itemID)?.sets.map(\.weightKg) == [60, 62.5])
        #expect(active.isWellFormed)
    }

    @Test("Logging past the planned count grows the plan — data beats scaffolding")
    func loggingPastPlanGrowsPlan() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var active = SessionBuilder.session(
            from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
            clock: clock,
            makeID: ids.make
        )
        let itemID = active.items[0].id

        for _ in 0..<3 {
            try SessionMutator.logSet(
                itemID: itemID, weight: Weight(kg: 40), reps: 10,
                in: &active, clock: clock, makeID: ids.make
            )
        }

        #expect(active.loggedSetCount(itemID) == 3)
        #expect(active.plannedSetCount(itemID) == 3)
        #expect(active.isWellFormed)
    }

    @Test("logSet rejects a set with no reps")
    func logSetRejectsZeroReps() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let itemID = active.items[0].id

        #expect(throws: SessionMutationError.invalidReps(0)) {
            try SessionMutator.logSet(
                itemID: itemID, weight: Weight(kg: 40), reps: 0,
                in: &active, clock: clock, makeID: ids.make
            )
        }
    }

    @Test("A bodyweight set (0 kg) is valid and logs normally")
    func logSetAcceptsBodyweight() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let itemID = active.items[1].id

        let record = try SessionMutator.logSet(
            itemID: itemID, weight: .bodyweight, reps: 12, isWarmup: true,
            in: &active, clock: clock, makeID: ids.make
        )

        #expect(record.weightKg == 0)
        #expect(record.isWarmup)
    }

    // MARK: - Skip

    @Test("skip exercise keeps the item, its place, and every logged set")
    func skipPreservesEverything() throws {
        var active = try startedSession().session
        let itemID = active.items[1].id
        let before = active

        try SessionMutator.skipExercise(itemID: itemID, in: &active)

        #expect(active.plan(itemID)?.isSkipped == true)
        #expect(active.allSets == before.allSets)
        #expect(active.items.map(\.id) == before.items.map(\.id))
        #expect(active.items.map(\.order) == [0, 1, 2])
        #expect(active.unskippedItems.map(\.id) == [before.items[0].id, before.items[2].id])
        #expect(active.isWellFormed)
    }

    @Test("skipping a middle item keeps pager ordinals dense and advances to the next visible item")
    func skippingMiddleItemKeepsPagerOrderAndAdvances() throws {
        var active = try startedSession().session
        let first = active.items[0].id
        let middle = active.items[1].id
        let last = active.items[2].id

        try SessionMutator.skipExercise(itemID: middle, in: &active)

        #expect(active.unskippedItemIndex(of: first) == 0)
        #expect(active.unskippedItemIndex(of: last) == 1)
        #expect(active.nextUnskippedItemID(after: middle) == last)
        #expect(active.nextUnskippedItemID(after: last) == first)
    }

    // MARK: - Swap

    @Test("swap with nothing logged yet replaces the exercise in place")
    func swapWithNothingLoggedIsInPlace() throws {
        let ids = SequentialIDs()
        var active = SessionBuilder.session(
            from: Fixture.routine(ids: ids), clock: ManualClock(), makeID: ids.make
        )
        let itemID = active.items[1].id
        let before = active
        let replacement = ids.next()

        let working = try SessionMutator.swapExercise(
            itemID: itemID, toExerciseID: replacement, in: &active, makeID: ids.make
        )

        // Nothing was performed here yet, so the slot is still scaffolding
        // and can simply become a different exercise.
        #expect(working == itemID)
        #expect(active.items.count == before.items.count)
        #expect(active.item(itemID)?.exerciseID == replacement)
        #expect(active.item(itemID)?.order == 1)
        #expect(active.plan(itemID) == before.plan(itemID))
        #expect(active.allSets == before.allSets)
        #expect(active.isWellFormed)
    }

    @Test("swap after logging splits: the logged sets keep their original exercise")
    func swapAfterLoggingSplitsAttribution() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let itemID = active.items[1].id            // 4 planned, 1 logged
        let before = active
        let originalExercise = before.item(itemID)!.exerciseID
        let performedSets = before.item(itemID)!.sets
        let replacement = ids.next()

        let working = try SessionMutator.swapExercise(
            itemID: itemID, toExerciseID: replacement, in: &active, makeID: ids.make
        )

        // Required up front so a regression to the in-place overwrite fails
        // here, cleanly, instead of trapping on an index further down.
        try #require(active.items.count == 4)
        try #require(working != itemID)

        // The performed half is frozen exactly as it happened. This is the
        // whole point: those reps were done for `originalExercise`, and no
        // swap may quietly re-file them as something else.
        #expect(active.item(itemID)?.exerciseID == originalExercise)
        #expect(active.item(itemID)?.exerciseID != replacement)
        #expect(active.item(itemID)?.sets == performedSets)
        #expect(active.item(itemID)?.order == 1)
        // Its plan shrinks to what it holds, so no empty slot is left
        // inviting more sets under the exercise the lifter just left.
        #expect(active.plannedSetCount(itemID) == 1)
        #expect(active.hasEmptySetSlot(itemID) == false)

        // The replacement arrives as a new item, directly after, carrying
        // the slots that were still outstanding.
        #expect(working != itemID)
        #expect(active.index(ofItem: working) == 2)
        #expect(active.item(working)?.exerciseID == replacement)
        #expect(active.item(working)?.sets.isEmpty == true)
        #expect(active.plannedSetCount(working) == 3)   // 4 planned − 1 logged
        #expect(active.plan(working)?.restOverride == before.plan(itemID)?.restOverride)
        #expect(active.plan(working)?.isSkipped == false)

        // Everything else is where it was, and no set anywhere was touched.
        #expect(active.items.count == 4)
        #expect(active.items.map(\.order) == [0, 1, 2, 3])
        #expect(active.items[0].id == before.items[0].id)
        #expect(active.items[3].id == before.items[2].id)
        #expect(active.allSets == before.allSets)
        #expect(active.isWellFormed)
    }

    @Test("A split still gives the replacement a slot when the old exercise used every planned set")
    func swapSplitAlwaysGivesReplacementOneSlot() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let itemID = active.items[2].id            // 2 planned, 1 logged
        try SessionMutator.logSet(
            itemID: itemID, weight: Weight(kg: 20), reps: 10,
            in: &active, clock: clock, makeID: ids.make
        )
        #expect(active.hasEmptySetSlot(itemID) == false)

        let working = try SessionMutator.swapExercise(
            itemID: itemID, toExerciseID: ids.next(), in: &active, makeID: ids.make
        )

        #expect(active.plannedSetCount(itemID) == 2)   // frozen at what it holds
        #expect(active.plannedSetCount(working) == 1)  // I4's floor, not zero
        #expect(active.loggedSetCount(working) == 0)
        #expect(active.isWellFormed)
    }

    @Test("Swapping twice on a part-logged exercise leaves one frozen half per exercise performed")
    func repeatedSwapsChainWithoutLosingAttribution() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let itemA = active.items[0].id             // 3 planned, 1 logged
        let exerciseA = active.item(itemA)!.exerciseID
        let exerciseB = ids.next()
        let exerciseC = ids.next()

        let itemB = try SessionMutator.swapExercise(
            itemID: itemA, toExerciseID: exerciseB, in: &active, makeID: ids.make
        )
        try SessionMutator.logSet(
            itemID: itemB, weight: Weight(kg: 55), reps: 6,
            in: &active, clock: clock, makeID: ids.make
        )
        let itemC = try SessionMutator.swapExercise(
            itemID: itemB, toExerciseID: exerciseC, in: &active, makeID: ids.make
        )

        try #require(active.items.count == 5)

        // Three items, three exercises, each holding only its own work.
        #expect(active.item(itemA)?.exerciseID == exerciseA)
        #expect(active.item(itemB)?.exerciseID == exerciseB)
        #expect(active.item(itemC)?.exerciseID == exerciseC)
        #expect(active.item(itemA)?.sets.map(\.weightKg) == [40])
        #expect(active.item(itemB)?.sets.map(\.weightKg) == [55])
        #expect(active.item(itemC)?.sets.isEmpty == true)
        #expect(Array(active.items.map(\.id).prefix(3)) == [itemA, itemB, itemC])
        #expect(active.items.map(\.order) == [0, 1, 2, 3, 4])
        #expect(active.isWellFormed)
    }

    // MARK: - Add exercise

    @Test("add exercise appends by default, leaving existing items and sets untouched")
    func addExerciseAppends() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let before = active
        let exerciseID = ids.next()

        let itemID = try SessionMutator.addExercise(
            exerciseID: exerciseID, plannedSetCount: 4, restOverride: 45,
            in: &active, makeID: ids.make
        )

        #expect(active.items.count == 4)
        #expect(active.items.last?.id == itemID)
        #expect(active.items.map(\.order) == [0, 1, 2, 3])
        #expect(active.plannedSetCount(itemID) == 4)
        #expect(active.plan(itemID)?.restOverride == 45)
        #expect(active.allSets == before.allSets)
        #expect(active.isWellFormed)
    }

    @Test("add exercise at an index inserts and renumbers everything after it")
    func addExerciseInserts() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let before = active

        let itemID = try SessionMutator.addExercise(
            exerciseID: ids.next(), at: 1, in: &active, makeID: ids.make
        )

        #expect(active.items.map(\.id) == [before.items[0].id, itemID, before.items[1].id, before.items[2].id])
        #expect(active.items.map(\.order) == [0, 1, 2, 3])
        #expect(active.allSets == before.allSets)
        #expect(active.isWellFormed)
    }

    @Test("add exercise rejects an out-of-range index")
    func addExerciseRejectsBadIndex() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids

        #expect(throws: SessionMutationError.indexOutOfRange(9)) {
            try SessionMutator.addExercise(exerciseID: ids.next(), at: 9, in: &active, makeID: ids.make)
        }
    }

    @Test("The 'Custom (name later)' placeholder is a needsNaming custom exercise with no invented tags")
    func placeholderExercise() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids

        let (itemID, exercise) = try SessionMutator.addPlaceholderExercise(
            in: &active, makeID: ids.make
        )

        #expect(exercise.needsNaming)
        #expect(exercise.origin == .custom)
        #expect(exercise.muscleGroups.isEmpty)
        #expect(exercise.name == SessionMutator.placeholderExerciseName)
        #expect(active.item(itemID)?.exerciseID == exercise.id)
        #expect(active.items.last?.id == itemID)
        #expect(active.isWellFormed)
    }

    // MARK: - Reorder

    @Test("move up swaps with the item above and renumbers; sets travel with their item")
    func moveUp() throws {
        var active = try startedSession().session
        let before = active
        let moved = active.items[2].id
        let movedSets = active.item(moved)!.sets

        try SessionMutator.moveItemUp(itemID: moved, in: &active)

        #expect(active.items.map(\.id) == [before.items[0].id, moved, before.items[1].id])
        #expect(active.items.map(\.order) == [0, 1, 2])
        #expect(active.item(moved)?.sets == movedSets)
        #expect(Set(active.allSets) == Set(before.allSets))
        #expect(active.isWellFormed)
    }

    @Test("move down swaps with the item below and renumbers")
    func moveDown() throws {
        var active = try startedSession().session
        let before = active
        let moved = active.items[0].id

        try SessionMutator.moveItemDown(itemID: moved, in: &active)

        #expect(active.items.map(\.id) == [before.items[1].id, moved, before.items[2].id])
        #expect(active.items.map(\.order) == [0, 1, 2])
        #expect(active.isWellFormed)
    }

    @Test("Moving off either edge is refused, and the helpers agree")
    func moveOffEdgeRefused() throws {
        var active = try startedSession().session
        let first = active.items[0].id
        let last = active.items[2].id

        #expect(SessionMutator.canMoveUp(itemID: first, in: active) == false)
        #expect(SessionMutator.canMoveDown(itemID: last, in: active) == false)
        #expect(throws: SessionMutationError.itemAlreadyAtEdge(itemID: first)) {
            try SessionMutator.moveItemUp(itemID: first, in: &active)
        }
        #expect(throws: SessionMutationError.itemAlreadyAtEdge(itemID: last)) {
            try SessionMutator.moveItemDown(itemID: last, in: &active)
        }
    }

    @Test("Reordering the whole list keeps plans attached to their items")
    func reorderKeepsPlansAttached() throws {
        var active = try startedSession().session
        let plansBefore = active.plans

        try SessionMutator.moveItemDown(itemID: active.items[0].id, in: &active)
        try SessionMutator.moveItemUp(itemID: active.items[2].id, in: &active)

        #expect(active.plans == plansBefore)
        #expect(active.isWellFormed)
    }

    // MARK: - Unknown item / finished session

    @Test("Every item-scoped mutation rejects an unknown item id")
    func unknownItemRejected() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        let ghost = ids.next()

        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.addSet(toItem: ghost, in: &active)
        }
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.removeEmptySet(fromItem: ghost, in: &active)
        }
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.skipExercise(itemID: ghost, in: &active)
        }
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.swapExercise(itemID: ghost, toExerciseID: ids.next(), in: &active)
        }
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.moveItemUp(itemID: ghost, in: &active)
        }
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try SessionMutator.logSet(
                itemID: ghost, weight: Weight(kg: 10), reps: 5,
                in: &active, clock: clock, makeID: ids.make
            )
        }
    }

    @Test("finish logs the session and stops the timer; the watch cannot edit it afterwards")
    func finishClosesTheSession() throws {
        let started = try startedSession()
        var active = started.session
        let ids = started.ids
        let clock = started.clock
        RestTimerEngine(clock: clock).start(&active.restTimer, itemOverride: nil)
        clock.advance(30)

        try SessionMutator.finish(&active, clock: clock)

        #expect(active.session.state == .logged)
        #expect(active.session.endedAt == clock.now)
        #expect(active.restTimer == nil)
        #expect(active.isActive == false)

        let itemID = active.items[0].id
        #expect(throws: SessionMutationError.sessionNotActive) {
            try SessionMutator.addSet(toItem: itemID, in: &active)
        }
        #expect(throws: SessionMutationError.sessionNotActive) {
            try SessionMutator.logSet(
                itemID: itemID, weight: Weight(kg: 10), reps: 5,
                in: &active, clock: clock, makeID: ids.make
            )
        }
        #expect(throws: SessionMutationError.sessionNotActive) {
            try SessionMutator.moveItemDown(itemID: itemID, in: &active)
        }
        #expect(throws: SessionMutationError.sessionNotActive) {
            try SessionMutator.finish(&active, clock: clock)
        }
    }
}
