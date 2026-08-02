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

    // MARK: - Double Tap

    @Test("Double Tap is one call: it logs the set with current values and never arms")
    func doubleTapLogsInOneCall() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        engine.prefillWeight(Weight(kg: 60))

        // No `logsSet` wiring at the call site — §2 calls Double Tap the
        // primary action, so the engine performs it.
        let outcome = try engine.handleDoubleTap(itemID: itemID, reps: 8, makeID: ids.make)

        #expect(engine.session.loggedSetCount(itemID) == 1)
        #expect(outcome.set.weightKg == 60)          // the control's current value
        #expect(outcome.set.reps == 8)
        #expect(outcome.haptics == [.setLogged])
        #expect(engine.weightEdit.isArmed == false)
        #expect(engine.restRemaining == 90)
    }

    @Test("Double Tap from an armed control locks it and returns both haptics in one outcome")
    func doubleTapFromArmedLocksAndLogs() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        engine.prefillWeight(Weight(kg: 60))
        engine.handleWeightEdit(.longPressArm)
        engine.handleWeightEdit(.adjust(steps: 2))

        let outcome = try engine.handleDoubleTap(itemID: itemID, reps: 8, makeID: ids.make)

        #expect(outcome.haptics == [.weightEditLocked, .setLogged])
        #expect(outcome.set.weightKg == 62.5)
        #expect(engine.weightEdit.isArmed == false)
        #expect(engine.session.loggedSetCount(itemID) == 1)
    }

    @Test("Repeated Double Taps log repeatedly and never accumulate into an armed control")
    func repeatedDoubleTapsLogAndNeverArm() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock, setCounts: [3], restOverrides: [nil])
        let itemID = engine.session.items[0].id
        engine.prefillWeight(Weight(kg: 40))

        for _ in 0..<5 {
            try engine.handleDoubleTap(itemID: itemID, reps: 10, makeID: ids.make)
            clock.advance(30)
            #expect(engine.weightEdit.isArmed == false)
        }

        #expect(engine.session.loggedSetCount(itemID) == 5)
    }

    @Test("A refused Double Tap logs nothing and leaves the control exactly as it was")
    func refusedDoubleTapIsAtomic() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        engine.handleWeightEdit(.longPressArm)
        let armed = engine.weightEdit

        #expect(throws: SessionMutationError.invalidReps(0)) {
            try engine.handleDoubleTap(itemID: itemID, reps: 0, makeID: ids.make)
        }

        #expect(engine.weightEdit == armed)
        #expect(engine.weightEdit.isArmed)
        #expect(engine.session.allSets.isEmpty)
    }

    // MARK: - Atomicity

    @Test("A refused log leaves the guarded control untouched and loses no haptic")
    func refusedLogDoesNotHalfCommit() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        let ghost = ids.next()

        engine.handleWeightEdit(.longPressArm)
        #expect(engine.weightEdit.isArmed)
        let armed = engine.weightEdit

        // A set with no reps is not a set …
        #expect(throws: SessionMutationError.invalidReps(0)) {
            try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 0, makeID: ids.make)
        }
        #expect(engine.weightEdit == armed)

        // … and neither is one against an item that is not there.
        #expect(throws: SessionMutationError.unknownItem(ghost)) {
            try engine.logSet(itemID: ghost, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        }
        #expect(engine.weightEdit == armed)

        // Nothing partial happened anywhere: still armed, no set, no rest.
        #expect(engine.weightEdit.isArmed)
        #expect(engine.session.allSets.isEmpty)
        #expect(engine.session.restTimer == nil)

        // And the lock haptic those failures did not consume is still owed:
        // the next real log emits it, as it always would have.
        let outcome = try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        #expect(outcome.haptics == [.weightEditLocked, .setLogged])
    }

    @Test("A log refused because the session is finished changes nothing either")
    func refusedLogOnFinishedSessionIsAtomic() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        let itemID = engine.session.items[0].id
        try engine.finish()
        engine.handleWeightEdit(.longPressArm)
        let armed = engine.weightEdit

        #expect(throws: SessionMutationError.sessionNotActive) {
            try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        }

        #expect(engine.weightEdit == armed)
        #expect(engine.session.allSets.isEmpty)
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
        // `first` has a set logged, so this swap splits it in two.
        let swapped = try engine.swapExercise(
            itemID: first, toExerciseID: ids.next(), makeID: ids.make
        )
        let added = try engine.addExercise(exerciseID: ids.next(), makeID: ids.make)
        try engine.moveItemUp(itemID: added)
        let placeholder = try engine.addPlaceholderExercise(makeID: ids.make)

        #expect(engine.session.isWellFormed)
        #expect(engine.session.loggedSetCount(first) == 1)
        #expect(engine.session.loggedSetCount(swapped) == 0)
        #expect(placeholder.exercise.needsNaming)
        #expect(engine.session.items.count == 6)
        #expect(engine.session.items.map(\.order) == [0, 1, 2, 3, 4, 5])
    }

    @Test("Finishing while the weight is armed returns the lock haptic instead of swallowing it")
    func finishReturnsTheLockHaptic() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        try engine.logSet(
            itemID: engine.session.items[0].id, weight: Weight(kg: 60), reps: 8, makeID: ids.make
        )
        engine.handleWeightEdit(.longPressArm)

        // §2: "every lock/unlock transition is a distinct haptic" — Finish
        // is not allowed to be the one silent transition.
        #expect(try engine.finish() == [.weightEditLocked])
        #expect(engine.weightEdit.isArmed == false)
    }

    @Test("Finishing with the weight already locked returns no haptic")
    func finishWithLockedWeightIsSilent() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        try engine.logSet(
            itemID: engine.session.items[0].id, weight: Weight(kg: 60), reps: 8, makeID: ids.make
        )

        #expect(try engine.finish().isEmpty)
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

        let haptics = try engine.finish()

        // Nothing ticked during those 45 s, so the idle auto-lock had never
        // been evaluated and its haptic was still owed. Finish evaluates it
        // and hands it back rather than dropping it on the floor.
        #expect(haptics == [.weightEditLocked])
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

    @Test("setCurrentItem is pure bookkeeping: it records the id, survives a crash/resume JSON round trip, and defaults to nil for every caller that never sets it (m2-06 review finding 1.1)")
    func setCurrentItemRecordsAndSurvivesRoundTrip() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = makeEngine(ids: ids, clock: clock)
        #expect(engine.session.currentItemID == nil)

        let secondItemID = engine.session.items[1].id
        engine.setCurrentItem(secondItemID)
        #expect(engine.session.currentItemID == secondItemID)

        // Not a rule -- setting it never touches sets, plans, or the timer.
        let beforeMutation = engine.session
        engine.setCurrentItem(nil)
        #expect(engine.session.currentItemID == nil)
        #expect(engine.session.allSets == beforeMutation.allSets)
        #expect(engine.session.plans == beforeMutation.plans)

        engine.setCurrentItem(secondItemID)
        let restored = try roundTripJSON(engine.session)
        #expect(restored.currentItemID == secondItemID)
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
