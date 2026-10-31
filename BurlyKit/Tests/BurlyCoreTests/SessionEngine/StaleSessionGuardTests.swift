// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §4 acceptance #5: the stale-session guard fires at the 1 h boundary
// (injected clock), measured from the last logged set.
import Testing
import Foundation
@testable import BurlyCore

@Suite("Stale-session guard — §4 1 h boundary")
struct StaleSessionGuardTests {
    @Test("Exactly one hour after the last set is not stale; one second more is")
    func boundaryFromLastSet() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [3], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id
        clock.advance(600)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        let lastSet = clock.now

        #expect(StaleSessionGuard.lastActivity(of: engine.session) == lastSet)
        #expect(!StaleSessionGuard.isStale(engine.session, now: lastSet.addingTimeInterval(3_600)))
        #expect(StaleSessionGuard.isStale(engine.session, now: lastSet.addingTimeInterval(3_601)))
    }

    @Test("A session with no sets measures from its start")
    func noSetsMeasuresFromStart() {
        let ids = SequentialIDs()
        let clock = ManualClock()
        let session = SessionBuilder.emptySession(clock: clock, makeID: ids.make)

        #expect(StaleSessionGuard.lastActivity(of: session) == clock.now)
        #expect(!StaleSessionGuard.isStale(session, now: clock.now.addingTimeInterval(3_600)))
        #expect(StaleSessionGuard.isStale(session, now: clock.now.addingTimeInterval(3_601)))
    }

    @Test("Finishing at the last set keeps the original timestamps")
    func finishEndingAtLastSet() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        try engine.logSet(itemID: engine.session.items[0].id, weight: Weight(kg: 40), reps: 5, makeID: ids.make)
        let lastSet = StaleSessionGuard.lastActivity(of: engine.session)
        clock.advance(3 * 3_600)

        try engine.finish(endingAt: lastSet)

        #expect(engine.session.session.state == .logged)
        #expect(engine.session.session.endedAt == lastSet)
    }

    @Test("Linking a HealthKit workout is allowed after Finish")
    func linkAfterFinish() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(session: SessionBuilder.emptySession(clock: clock, makeID: ids.make), clock: clock)
        try engine.finish()
        let workoutID = UUID()

        engine.linkHealthKitWorkout(workoutID)

        #expect(engine.session.session.healthKitWorkoutID == workoutID)
    }
}
