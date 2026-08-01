// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #2: "locked→armed only via arm action; armed→locked on
// 3 s idle / log / page-away; adjust events while locked are no-ops",
// plus §2's "every lock/unlock transition is a distinct haptic".
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 Guarded weight edit")
struct GuardedWeightEditMachineTests {
    private func makeMachine(
        clock: ManualClock,
        increment: Weight = Weight(kg: 1.25),
        idleTimeout: TimeInterval = 3
    ) -> GuardedWeightEditMachine {
        GuardedWeightEditMachine(
            configuration: .init(idleTimeout: idleTimeout, increment: increment),
            clock: clock
        )
    }

    // MARK: - Default state

    @Test("The weight control starts locked")
    func startsLocked() {
        let state = WeightEditState(weight: Weight(kg: 60))
        #expect(state.lock == .locked)
        #expect(state.isArmed == false)
        #expect(state.weight.kg == 60)
    }

    // MARK: - Arming

    @Test("Long press is the arm: locked→armed with a distinct haptic")
    func longPressArms() {
        let clock = ManualClock()
        var state = WeightEditState(weight: Weight(kg: 60))

        let effect = makeMachine(clock: clock).handle(.longPressArm, &state)

        #expect(state.lock == .armed)
        #expect(effect.haptics == [.weightEditArmed])
        #expect(effect.logsSet == false)
    }

    @Test("No event other than long press can ever reach the armed state")
    func onlyLongPressArms() {
        let clock = ManualClock()
        let others: [WeightEditEvent] = [
            .adjust(steps: 1), .adjust(steps: -4), .logSet, .doubleTap, .pageAway, .idleTick
        ]

        for event in others {
            var state = WeightEditState(weight: Weight(kg: 60))
            let effect = makeMachine(clock: clock).handle(event, &state)
            #expect(state.lock == .locked, "\(event) armed the control")
            #expect(effect.haptics.contains(.weightEditArmed) == false, "\(event) fired an arm haptic")
        }
    }

    @Test("Re-arming an already-armed control fires no second haptic but refreshes the idle window")
    func reArmRefreshesWithoutHaptic() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        clock.advance(2)
        let effect = machine.handle(.longPressArm, &state)

        #expect(effect.haptics.isEmpty)
        #expect(state.lock == .armed)
        #expect(machine.timeUntilAutoLock(state) == 3)
    }

    // MARK: - Adjust

    @Test("Adjust while locked is a no-op: the weight does not move and nothing buzzes")
    func adjustWhileLockedIsNoOp() {
        let clock = ManualClock()
        var state = WeightEditState(weight: Weight(kg: 60))

        let up = makeMachine(clock: clock).handle(.adjust(steps: 4), &state)
        let down = makeMachine(clock: clock).handle(.adjust(steps: -10), &state)

        #expect(state.weight.kg == 60)
        #expect(state.lock == .locked)
        #expect(up.haptics.isEmpty)
        #expect(up.weightChanged == false)
        #expect(down.weightChanged == false)
    }

    @Test("Adjust while armed moves the weight by the configured increment")
    func adjustWhileArmedMovesWeight() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        let up = machine.handle(.adjust(steps: 2), &state)
        #expect(state.weight.kg == 62.5)
        #expect(up.weightChanged)

        machine.handle(.adjust(steps: -1), &state)
        #expect(state.weight.kg == 61.25)
        #expect(state.lock == .armed)
    }

    @Test("Adjusting down past zero floors at bodyweight rather than going negative")
    func adjustFloorsAtZero() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 2.5))
        machine.handle(.longPressArm, &state)

        machine.handle(.adjust(steps: -10), &state)

        #expect(state.weight.kg == 0)
    }

    // MARK: - Auto-lock

    @Test("Three seconds of inactivity auto-locks, with a lock haptic")
    func idleAutoLocks() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        clock.advance(2.9)
        #expect(machine.handle(.idleTick, &state).haptics.isEmpty)
        #expect(state.lock == .armed)

        clock.advance(0.1)
        let effect = machine.handle(.idleTick, &state)

        #expect(state.lock == .locked)
        #expect(effect.haptics == [.weightEditLocked])
    }

    @Test("Activity refreshes the idle window — two 2.9 s gaps do not add up to a lock")
    func activityRefreshesIdleWindow() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        clock.advance(2.9)
        machine.handle(.adjust(steps: 1), &state)
        clock.advance(2.9)
        machine.handle(.idleTick, &state)

        #expect(state.lock == .armed)
        #expect(state.weight.kg == 61.25)
    }

    @Test("A late adjust is ignored: idle expiry is applied before the event, even with no ticks")
    func lateAdjustIsIgnoredWithoutTicks() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        // No idleTick at all — a suspended process, or a crown turn that
        // arrives after the watch slept. The expiry still applies.
        clock.advance(10)
        let effect = machine.handle(.adjust(steps: 4), &state)

        #expect(state.lock == .locked)
        #expect(state.weight.kg == 60)
        #expect(effect.weightChanged == false)
        #expect(effect.haptics == [.weightEditLocked])
    }

    @Test("Logging the set auto-locks with a haptic and reports logsSet")
    func logSetLocks() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        let effect = machine.handle(.logSet, &state)

        #expect(state.lock == .locked)
        #expect(effect.haptics == [.weightEditLocked])
        #expect(effect.logsSet)
    }

    @Test("Paging away auto-locks with a haptic")
    func pageAwayLocks() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        let effect = machine.handle(.pageAway, &state)

        #expect(state.lock == .locked)
        #expect(effect.haptics == [.weightEditLocked])
        #expect(effect.logsSet == false)
    }

    @Test("Locking an already-locked control fires nothing — haptics mark transitions only")
    func lockingWhenLockedIsSilent() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))

        #expect(machine.handle(.pageAway, &state).haptics.isEmpty)
        #expect(machine.handle(.logSet, &state).haptics.isEmpty)
        #expect(machine.handle(.idleTick, &state).haptics.isEmpty)
    }

    // MARK: - Double Tap

    @Test("Double Tap logs the set and never arms — from locked it stays locked")
    func doubleTapFromLockedLogsWithoutArming() {
        let clock = ManualClock()
        var state = WeightEditState(weight: Weight(kg: 60))

        let effect = makeMachine(clock: clock).handle(.doubleTap, &state)

        #expect(effect.logsSet)
        #expect(state.lock == .locked)
        #expect(effect.haptics.isEmpty)
    }

    @Test("Double Tap while armed logs and locks, exactly like the Log set button")
    func doubleTapFromArmedLocks() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        machine.handle(.longPressArm, &state)

        let effect = machine.handle(.doubleTap, &state)

        #expect(effect.logsSet)
        #expect(state.lock == .locked)
        #expect(effect.haptics == [.weightEditLocked])
    }

    @Test("Repeated Double Taps can never accumulate into an armed control")
    func repeatedDoubleTapsNeverArm() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))

        for _ in 0..<20 {
            machine.handle(.doubleTap, &state)
            clock.advance(0.4)
            #expect(state.lock == .locked)
        }
    }

    // MARK: - Haptic log

    @Test("A full arm→adjust→idle-lock→arm→log cycle emits exactly the transition haptics")
    func fullCycleHapticLog() {
        let clock = ManualClock()
        let machine = makeMachine(clock: clock)
        var state = WeightEditState(weight: Weight(kg: 60))
        var log = HapticLog()

        log.record(contentsOf: machine.handle(.longPressArm, &state).haptics)
        log.record(contentsOf: machine.handle(.adjust(steps: 2), &state).haptics)
        clock.advance(3)
        log.record(contentsOf: machine.handle(.idleTick, &state).haptics)
        log.record(contentsOf: machine.handle(.longPressArm, &state).haptics)
        log.record(contentsOf: machine.handle(.logSet, &state).haptics)

        #expect(log.events == [.weightEditArmed, .weightEditLocked, .weightEditArmed, .weightEditLocked])
        #expect(log.count(of: .weightEditArmed) == 2)
        #expect(log.count(of: .weightEditLocked) == 2)
    }

    @Test("Prefilling a value neither arms the control nor refreshes the idle window")
    func prefillDoesNotArm() {
        let clock = ManualClock()
        var state = WeightEditState(weight: Weight(kg: 60))

        state.prefill(Weight(kg: 80))

        #expect(state.weight.kg == 80)
        #expect(state.lock == .locked)
        #expect(makeMachine(clock: clock).timeUntilAutoLock(state) == nil)
    }

    @Test("WeightEditState round-trips through JSON")
    func stateRoundTrips() throws {
        let clock = ManualClock()
        var state = WeightEditState(weight: Weight(kg: 60))
        makeMachine(clock: clock).handle(.longPressArm, &state)

        #expect(try roundTripJSON(state) == state)
    }
}
