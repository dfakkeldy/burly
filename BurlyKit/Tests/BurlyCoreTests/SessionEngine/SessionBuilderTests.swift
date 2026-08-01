// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #1, first half: routine→session copy.
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 Start — routine→session copy")
struct SessionBuilderTests {
    @Test("Copies routine identity and denormalizes the routine name")
    func copiesRoutineIdentity() {
        let ids = SequentialIDs()
        let routine = Fixture.routine(ids: ids)
        let clock = ManualClock()

        let active = SessionBuilder.session(from: routine, clock: clock, makeID: ids.make)

        #expect(active.session.routineID == routine.id)
        #expect(active.session.routineName == "Push A")
    }

    @Test("Session starts at the clock's instant, active, revision 1, live origin")
    func sessionHeaderDefaults() {
        let ids = SequentialIDs()
        let clock = ManualClock()
        let active = SessionBuilder.session(from: Fixture.routine(ids: ids), clock: clock, makeID: ids.make)

        #expect(active.session.startedAt == clock.now)
        #expect(active.session.endedAt == nil)
        #expect(active.session.state == .active)
        #expect(active.session.revision == 1)
        #expect(active.session.origin == .live)
        #expect(active.session.healthKitWorkoutID == nil)
        #expect(active.restTimer == nil)
    }

    @Test("Items are copied in order with dense order fields and no sets")
    func itemsCopiedDensely() {
        let ids = SequentialIDs()
        let routine = Fixture.routine(ids: ids)
        let active = SessionBuilder.session(from: routine, clock: ManualClock(), makeID: ids.make)

        #expect(active.items.count == routine.items.count)
        #expect(active.items.map(\.order) == [0, 1, 2])
        #expect(active.items.map(\.exerciseID) == routine.items.map(\.exerciseID))
        #expect(active.items.allSatisfy { $0.sets.isEmpty })
        #expect(active.isWellFormed)
    }

    @Test("Session items get fresh ids — the session is a copy, not a reference to the template")
    func itemsGetFreshIdentity() {
        let ids = SequentialIDs()
        let routine = Fixture.routine(ids: ids)
        let active = SessionBuilder.session(from: routine, clock: ManualClock(), makeID: ids.make)

        let routineItemIDs = Set(routine.items.map(\.id))
        #expect(active.items.allSatisfy { !routineItemIDs.contains($0.id) })
    }

    @Test("Each item gets defaultSetCount empty set slots and the item's rest override")
    func plansSeededFromTemplate() {
        let ids = SequentialIDs()
        let routine = Fixture.routine(ids: ids, setCounts: [3, 4, 2], restOverrides: [nil, nil, 120])
        let active = SessionBuilder.session(from: routine, clock: ManualClock(), makeID: ids.make)

        #expect(active.items.map { active.plannedSetCount($0.id) } == [3, 4, 2])
        #expect(active.items.map { active.plan($0.id)?.restOverride } == [nil, nil, 120])
        #expect(active.items.allSatisfy { active.plan($0.id)?.isSkipped == false })
        // Every slot is empty, so every item can lose one (§2 remove empty set).
        #expect(active.items.allSatisfy { active.hasEmptySetSlot($0.id) })
    }

    @Test("Sparse, duplicated, and out-of-order template order values normalize to a dense 0-based copy")
    func normalizesTemplateOrdering() {
        let ids = SequentialIDs()
        let first = RoutineItemData(id: ids.next(), exerciseID: ids.next(), order: 7)
        let second = RoutineItemData(id: ids.next(), exerciseID: ids.next(), order: 2)
        let third = RoutineItemData(id: ids.next(), exerciseID: ids.next(), order: 2)
        let routine = RoutineData(
            id: ids.next(),
            name: "Messy",
            orderIndex: 0,
            items: [first, second, third],
            updatedAt: Date()
        )

        let active = SessionBuilder.session(from: routine, clock: ManualClock(), makeID: ids.make)

        #expect(active.items.map(\.order) == [0, 1, 2])
        // order 2 before order 7; the duplicate pair keeps template array order.
        #expect(active.items.map(\.exerciseID) == [second.exerciseID, third.exerciseID, first.exerciseID])
        #expect(active.isWellFormed)
    }

    @Test("A template item with 0 default sets still gets one slot (invariant I4)")
    func zeroSetTemplateItemGetsOneSlot() {
        let ids = SequentialIDs()
        let routine = Fixture.routine(ids: ids, setCounts: [0], restOverrides: [nil])
        let active = SessionBuilder.session(from: routine, clock: ManualClock(), makeID: ids.make)

        #expect(active.plannedSetCount(active.items[0].id) == 1)
        #expect(active.isWellFormed)
    }

    @Test("Empty session has no routine and no items")
    func emptySession() {
        let ids = SequentialIDs()
        let clock = ManualClock()
        let active = SessionBuilder.emptySession(clock: clock, makeID: ids.make)

        #expect(active.session.routineID == nil)
        #expect(active.session.routineName == nil)
        #expect(active.items.isEmpty)
        #expect(active.plans.isEmpty)
        #expect(active.session.state == .active)
        #expect(active.isWellFormed)
    }

    @Test("ActiveSession round-trips through JSON — the crash journal can store it whole")
    func activeSessionRoundTripsThroughJSON() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var active = SessionBuilder.session(from: Fixture.routine(ids: ids), clock: clock, makeID: ids.make)
        try SessionMutator.logSet(
            itemID: active.items[0].id,
            weight: Weight(kg: 60),
            reps: 8,
            in: &active,
            clock: clock,
            makeID: ids.make
        )
        RestTimerEngine(clock: clock).start(&active.restTimer, itemOverride: nil)

        let decoded = try roundTripJSON(active)

        #expect(decoded == active)
        #expect(decoded.plans == active.plans)
        #expect(decoded.restTimer?.endDate == active.restTimer?.endDate)
    }
}
