// SPDX-License-Identifier: GPL-3.0-or-later
// The three cross-cutting logging rules (§2 logging haptic + auto-lock,
// §3 auto-start on every set including warmups, next-set restart), and the
// crash/resume path that carries the whole thing.
import Testing
import Foundation
@testable import BurlyCore

@Suite("Session engine — logging wires §2 and §3 together")
struct SessionEngineTests {
    private func makeEngine(
        ids: SequentialIDs,
        clock: ManualClock,
        setCounts: [Int] = [3, 4, 2],
        restOverrides: [TimeInterval?] = [nil, nil, 120]
    ) -> SessionEngine {
        SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: setCounts, restOverrides: restOverrides),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
    }

    @Test("Logging a set fires the success haptic and starts the rest timer")
    func loggingStartsRest() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id

        let outcome = try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)

        #expect(outcome.haptics == [.setLogged])
        #expect(outcome.set.completedAt == clock.now)
        #expect(engine.session.restTimer?.endDate == clock.now.addingTimeInterval(90))
        #expect(engine.restRemaining == 90)
    }

    @Test("Logging while the weight is armed locks it first, then fires the success haptic")
    func loggingLocksArmedWeight() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id

        engine.handleWeightEdit(.longPressArm)
        engine.handleWeightEdit(.adjust(steps: 2))
        #expect(engine.weightEdit.isArmed)

        let outcome = try engine.logSet(
            itemID: itemID, weight: engine.weightEdit.weight, reps: 8, makeID: ids.make
        )

        #expect(outcome.haptics == [.weightEditLocked, .setLogged])
        #expect(engine.weightEdit.isArmed == false)
    }

    @Test("The rest timer honours the item's rest override (§3 resolution order)")
    func restUsesItemOverride() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let overridden = engine.session.items[2].id   // restOverride 120

        try engine.logSet(itemID: overridden, weight: Weight(kg: 20), reps: 12, makeID: ids.make)

        #expect(engine.restRemaining == 120)
    }

    @Test("Warmup sets start the rest timer too — §3 makes no distinction")
    func warmupSetsAlsoRest() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id

        let outcome = try engine.logSet(
            itemID: itemID, weight: Weight(kg: 20), reps: 10, isWarmup: true, makeID: ids.make
        )

        #expect(outcome.set.isWarmup)
        #expect(engine.restRemaining == 90)
    }

    @Test("Logging the next set cancels the running timer and starts a fresh one")
    func nextSetCancelsAndRestarts() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id

        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        clock.advance(85)
        #expect(engine.tick().contains(.restTimerWarning))
        #expect(engine.restRemaining == 5)

        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 7, makeID: ids.make)

        #expect(engine.restRemaining == 90)
        #expect(engine.session.restTimer?.warningFired == false)
        #expect(engine.session.restTimer?.startedAt == clock.now)
    }

    @Test("tick drives both machines: the weight auto-lock and the rest marks")
    func tickDrivesBothMachines() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)

        clock.advance(87)
        engine.handleWeightEdit(.longPressArm)
        clock.advance(3)

        let haptics = engine.tick()

        #expect(haptics == [.weightEditLocked, .restTimerFinished])
        #expect(engine.weightEdit.isArmed == false)
    }

    @Test("Paging away locks the weight (§2 auto-lock on page-away)")
    func pagingAwayLocks() {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        engine.handleWeightEdit(.longPressArm)

        #expect(engine.pageAway() == [.weightEditLocked])
        #expect(engine.weightEdit.isArmed == false)
    }

    @Test("Double Tap reports logsSet without arming, and the engine logs on that report")
    func doubleTapLogsWithoutArming() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        engine.prefillWeight(Weight(kg: 60))

        let effect = engine.handleWeightEdit(.doubleTap)
        #expect(effect.logsSet)
        #expect(engine.weightEdit.isArmed == false)

        if effect.logsSet {
            try engine.logSet(itemID: itemID, weight: engine.weightEdit.weight, reps: 8, makeID: ids.make)
        }

        #expect(engine.session.loggedSetCount(itemID) == 1)
        #expect(engine.session.item(itemID)?.sets.first?.weightKg == 60)
    }

    @Test("Prefill walks §2's ladder as a session progresses")
    func prefillLadderAcrossASession() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        let exerciseID = engine.session.item(itemID)!.exerciseID!
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60, 65], reps: [10, 8])

        #expect(engine.prefill(forItem: itemID, lastPerformance: digest).weight == Weight(kg: 60))
        try engine.logSet(itemID: itemID, weight: Weight(kg: 62.5), reps: 9, makeID: ids.make)

        #expect(engine.prefill(forItem: itemID, lastPerformance: digest).weight == Weight(kg: 65))
        try engine.logSet(itemID: itemID, weight: Weight(kg: 62.5), reps: 8, makeID: ids.make)

        // Third set: the digest has run out, so this session's last set stands in.
        let third = engine.prefill(forItem: itemID, lastPerformance: digest)
        #expect(third.source == .previousSetThisSession)
        #expect(third.weight == Weight(kg: 62.5))
        #expect(third.reps == 8)

        // With no digest at all, the very first set is empty.
        let untouched = engine.session.items[1].id
        #expect(engine.prefill(forItem: untouched, lastPerformance: nil) == .empty)
    }

    @Test("Mid-session edits are reachable from the engine and keep the session well formed")
    func structuralEditsThroughEngine() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let first = engine.session.items[0].id
        try engine.logSet(itemID: first, weight: Weight(kg: 60), reps: 8, makeID: ids.make)

        try engine.addSet(toItem: first)
        try engine.removeEmptySet(fromItem: first)
        try engine.skipExercise(itemID: engine.session.items[1].id)
        try engine.swapExercise(itemID: first, toExerciseID: ids.next())
        let added = try engine.addExercise(exerciseID: ids.next(), makeID: ids.make)
        try engine.moveItemUp(itemID: added)
        let placeholder = try engine.addPlaceholderExercise(makeID: ids.make)

        #expect(engine.session.isWellFormed)
        #expect(engine.session.loggedSetCount(first) == 1)
        #expect(placeholder.exercise.needsNaming)
        #expect(engine.session.items.map(\.order) == [0, 1, 2, 3, 4])
    }

    @Test("Finish closes the session, clears the timer, and locks the weight")
    func finishClosesEverything() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        engine.handleWeightEdit(.longPressArm)
        clock.advance(45)

        try engine.finish()

        #expect(engine.session.session.state == .logged)
        #expect(engine.session.session.endedAt == clock.now)
        #expect(engine.session.restTimer == nil)
        #expect(engine.weightEdit.isArmed == false)
        #expect(throws: SessionMutationError.sessionNotActive) {
            try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        }
    }

    @Test("Crash and resume: the whole active session survives JSON, sets intact and rest on schedule")
    func crashAndResume() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        clock.advance(10)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 62.5), reps: 6, makeID: ids.make)

        // 50 s pass with the process dead.
        clock.advance(50)
        let restored = try roundTripJSON(engine.session)
        var resumed = SessionEngine(session: restored, clock: clock)

        #expect(resumed.session.allSets == engine.session.allSets)
        #expect(resumed.session.loggedSetCount(itemID) == 2)
        #expect(resumed.restRemaining == 40)
        // §2: the weight control always comes back locked after a relaunch.
        #expect(resumed.weightEdit.lock == .locked)

        clock.advance(30)
        #expect(resumed.tick() == [.restTimerWarning])
        clock.advance(10)
        #expect(resumed.tick() == [.restTimerFinished])
    }

    @Test("A full three-set exercise produces the expected haptic log end to end")
    func endToEndHapticLog() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock, setCounts: [3], restOverrides: [nil])
        let itemID = engine.session.items[0].id
        var log = HapticLog()

        for setIndex in 0..<3 {
            if setIndex == 1 {
                // Bumped the weight for the working set.
                log.record(contentsOf: engine.handleWeightEdit(.longPressArm).haptics)
                log.record(contentsOf: engine.handleWeightEdit(.adjust(steps: 4)).haptics)
            }
            let outcome = try engine.logSet(
                itemID: itemID, weight: engine.weightEdit.weight, reps: 8, makeID: ids.make
            )
            log.record(contentsOf: outcome.haptics)

            // Rest the full 90 s, screen down.
            for _ in 0..<95 {
                clock.advance(1)
                log.record(contentsOf: engine.tick())
            }
        }

        #expect(engine.session.loggedSetCount(itemID) == 3)
        #expect(log.events == [
            .setLogged, .restTimerWarning, .restTimerFinished, .restTimerFinishedRepeat,
            .weightEditArmed, .weightEditLocked, .setLogged,
            .restTimerWarning, .restTimerFinished, .restTimerFinishedRepeat,
            .setLogged, .restTimerWarning, .restTimerFinished, .restTimerFinishedRepeat
        ])
    }
}
