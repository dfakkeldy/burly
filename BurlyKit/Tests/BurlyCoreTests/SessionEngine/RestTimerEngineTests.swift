// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §3 acceptance #1: "resolution order (override→routine→global);
// endDate math under simulated suspension gaps; adjust/skip transitions;
// next-set restart", and #4: "haptic events fired through the haptics
// abstraction are asserted in unit tests (0-mark, warning, repeat-once
// logic)".
import Testing
import Foundation
@testable import BurlyCore

@Suite("§3 Rest timer — duration resolution")
struct RestDurationTests {
    @Test("Item override wins over routine default, which wins over global")
    func resolutionOrder() {
        #expect(RestDuration.resolve(itemOverride: 120, routineDefault: 60, globalDefault: 90) == 120)
        #expect(RestDuration.resolve(itemOverride: nil, routineDefault: 60, globalDefault: 90) == 60)
        #expect(RestDuration.resolve(itemOverride: nil, routineDefault: nil, globalDefault: 90) == 90)
    }

    @Test("The global default is 90 s when nothing is configured at all")
    func globalDefaultIs90() {
        #expect(RestDuration.globalDefault == 90)
        #expect(RestDuration.resolve(itemOverride: nil) == 90)
    }

    @Test("Durations clamp to 15 s…5 min", arguments: [
        (0.0, 15.0), (1.0, 15.0), (15.0, 15.0), (300.0, 300.0), (301.0, 300.0), (3600.0, 300.0)
    ])
    func clampsToRange(raw: TimeInterval, expected: TimeInterval) {
        #expect(RestDuration.clamped(raw) == expected)
    }

    @Test("Off-grid durations snap to the nearest 15 s step", arguments: [
        (100.0, 105.0), (92.0, 90.0), (98.0, 105.0), (37.0, 30.0), (38.0, 45.0)
    ])
    func snapsToStep(raw: TimeInterval, expected: TimeInterval) {
        #expect(RestDuration.clamped(raw) == expected)
    }

    @Test("Resolution clamps whatever it resolved — an out-of-range override cannot escape")
    func resolutionClamps() {
        #expect(RestDuration.resolve(itemOverride: 9999) == 300)
        #expect(RestDuration.resolve(itemOverride: 1) == 15)
        #expect(RestDuration.resolve(itemOverride: nil, routineDefault: 100) == 105)
    }
}

@Suite("§3 Rest timer — engine")
struct RestTimerEngineTests {
    private func makeEngine(
        clock: ManualClock,
        routineDefault: TimeInterval? = nil,
        warningEnabled: Bool = true
    ) -> RestTimerEngine {
        RestTimerEngine(
            configuration: RestTimerConfiguration(
                routineDefault: routineDefault,
                warningEnabled: warningEnabled
            ),
            clock: clock
        )
    }

    // MARK: - Start

    @Test("Starting stores an endDate at now + resolved duration")
    func startStoresEndDate() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock, routineDefault: 60)
        var state: RestTimerState?

        let timer = engine.start(&state, itemOverride: 120)

        #expect(timer.startedAt == clock.now)
        #expect(timer.endDate == clock.now.addingTimeInterval(120))
        #expect(timer.duration == 120)
        #expect(state == timer)
    }

    @Test("Starting without an item override falls back through routine then global")
    func startUsesResolutionOrder() {
        let clock = ManualClock()
        var state: RestTimerState?

        makeEngine(clock: clock, routineDefault: 60).start(&state, itemOverride: nil)
        #expect(state?.duration == 60)

        makeEngine(clock: clock).start(&state, itemOverride: nil)
        #expect(state?.duration == 90)
    }

    // MARK: - Wall clock

    @Test("Remaining is wall-clock subtraction: a suspension gap consumes the countdown, never pauses it")
    func remainingIsWallClock() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(1)
        #expect(engine.remaining(state) == 89)

        // The watch slept for 40 s without a single tick.
        clock.advance(40)
        #expect(engine.remaining(state) == 49)

        // …and then for far longer than the timer.
        clock.advance(600)
        #expect(engine.remaining(state) == 0)
        #expect(engine.isRunning(state) == false)
    }

    @Test("A crash-and-resume round trip shows the correct wall-clock remainder, not a reset")
    func survivesRoundTripWithCorrectRemainder() throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        // 50 s pass with the app dead; the state comes back off disk.
        clock.advance(50)
        var resumed: RestTimerState? = try roundTripJSON(state!)

        #expect(engine.remaining(resumed) == 40)
        #expect(resumed?.endDate == state?.endDate)

        // …and the resumed timer keeps running from there, on schedule.
        #expect(engine.tick(&resumed).isEmpty)
        clock.advance(30)
        #expect(engine.tick(&resumed) == [.restTimerWarning])
        clock.advance(10)
        #expect(engine.tick(&resumed) == [.restTimerFinished])
    }

    // MARK: - Adjust and skip

    @Test("+15 s and −15 s move the total duration and the endDate with it")
    func adjustMovesEndDate() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        let start = engine.start(&state, itemOverride: 90)

        engine.adjust(&state, by: 15)
        #expect(state?.duration == 105)
        #expect(state?.endDate == start.startedAt.addingTimeInterval(105))

        engine.adjust(&state, by: -15)
        #expect(state?.duration == 90)
        #expect(state?.endDate == start.endDate)
    }

    @Test("Adjusting cannot leave the 15 s…5 min range")
    func adjustClampsToRange() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 300)

        engine.adjust(&state, by: 15)
        #expect(state?.duration == 300)

        engine.start(&state, itemOverride: 15)
        engine.adjust(&state, by: -15)
        #expect(state?.duration == 15)
    }

    @Test("Adjusting down past the current elapsed time finishes the timer immediately")
    func adjustDownPastNowFinishes() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)
        clock.advance(78)

        let haptics = engine.adjust(&state, by: -15)

        #expect(state?.duration == 75)
        #expect(engine.remaining(state) == 0)
        #expect(haptics == [.restTimerFinished])
    }

    @Test("Extending past the warning threshold re-arms the warning")
    func extendingReArmsWarning() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(85)
        #expect(engine.tick(&state) == [.restTimerWarning])

        engine.adjust(&state, by: 15)      // 20 s remain
        #expect(state?.warningFired == false)
        clock.advance(11)                  // 9 s remain
        #expect(engine.tick(&state) == [.restTimerWarning])
    }

    @Test("Extending a timer that already finished does not buzz a warning on the way out again")
    func extendingAFinishedTimerDoesNotRepeatTheWarning() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        // One jump straight past zero, so the warning never got a chance to
        // fire before the finish — it is suppressed, and stays suppressed.
        clock.advance(96)
        #expect(engine.tick(&state) == [.restTimerFinished, .restTimerFinishedRepeat])

        // +15 s puts 9 s back on the clock — under the warning threshold,
        // so the warning stays latched rather than firing a second time.
        #expect(engine.adjust(&state, by: 15).isEmpty)
        #expect(engine.remaining(state) == 9)
        #expect(state?.warningFired == true)
        clock.advance(5)
        #expect(engine.tick(&state).isEmpty)
        clock.advance(4)
        #expect(engine.tick(&state) == [.restTimerFinished])
    }

    @Test("Tap-to-skip clears the timer and fires nothing")
    func skipClearsSilently() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)
        clock.advance(10)

        engine.skip(&state)

        #expect(state == nil)
        #expect(engine.remaining(state) == 0)
        #expect(engine.tick(&state).isEmpty)
    }

    @Test("Starting again cancels the running timer and starts fresh — the next-set restart")
    func nextSetRestartsTimer() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)
        clock.advance(85)
        engine.tick(&state)                 // warning fired on the first timer

        clock.advance(5)
        let second = engine.start(&state, itemOverride: 90)

        #expect(second.startedAt == clock.now)
        #expect(second.endDate == clock.now.addingTimeInterval(90))
        #expect(second.warningFired == false)
        #expect(second.finishedFired == false)
        #expect(engine.remaining(state) == 90)
    }

    // MARK: - Haptics

    @Test("The 10 s warning fires once, at the threshold")
    func warningFiresOnce() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(79)
        #expect(engine.tick(&state).isEmpty)     // 11 s left
        clock.advance(1)
        #expect(engine.tick(&state) == [.restTimerWarning])   // 10 s left
        clock.advance(1)
        #expect(engine.tick(&state).isEmpty)     // already fired
    }

    @Test("The warning can be switched off (§3 setting, default on)")
    func warningCanBeDisabled() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock, warningEnabled: false)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(85)

        #expect(engine.tick(&state).isEmpty)
        clock.advance(5)
        #expect(engine.tick(&state) == [.restTimerFinished])
    }

    @Test("The 0-mark haptic fires exactly once, however many times tick is called")
    func zeroMarkFiresOnce() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock, warningEnabled: false)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(90)
        #expect(engine.tick(&state) == [.restTimerFinished])
        #expect(engine.tick(&state).isEmpty)
        clock.advance(1)
        #expect(engine.tick(&state).isEmpty)
    }

    @Test("The 0-mark repeats once at +5 s when the screen never woke")
    func repeatFiresWhenScreenNeverWoke() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock, warningEnabled: false)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(90)
        #expect(engine.tick(&state) == [.restTimerFinished])
        clock.advance(4)
        #expect(engine.tick(&state).isEmpty)
        clock.advance(1)
        #expect(engine.tick(&state) == [.restTimerFinishedRepeat])
        clock.advance(30)
        #expect(engine.tick(&state).isEmpty, "the repeat is once, not a nag")
    }

    @Test("The repeat is suppressed when the screen woke during the rest")
    func repeatSuppressedAfterScreenWake() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock, warningEnabled: false)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        clock.advance(30)
        engine.noteScreenWake(&state)
        clock.advance(60)
        #expect(engine.tick(&state) == [.restTimerFinished])
        clock.advance(5)
        #expect(engine.tick(&state).isEmpty)
    }

    @Test("A suspension gap past 0+5 s emits the finish and its repeat in one evaluation, and no stale warning")
    func suspensionGapEmitsBothMarksAndNoWarning() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        engine.start(&state, itemOverride: 90)

        // Wrist down for three minutes; the first tick after wake sees a
        // timer that ended long ago.
        clock.advance(180)
        let haptics = engine.tick(&state)

        #expect(haptics == [.restTimerFinished, .restTimerFinishedRepeat])
        #expect(haptics.contains(.restTimerWarning) == false)
        #expect(engine.tick(&state).isEmpty)
    }

    @Test("Rest timer haptics across a whole rest are exactly warning, finish, repeat")
    func fullRestHapticLog() {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        var state: RestTimerState?
        var log = HapticLog()
        engine.start(&state, itemOverride: 90)

        for _ in 0..<100 {
            clock.advance(1)
            log.record(contentsOf: engine.tick(&state))
        }

        #expect(log.events == [.restTimerWarning, .restTimerFinished, .restTimerFinishedRepeat])
    }

    @Test("Ticking with no timer is a no-op")
    func tickWithNoTimer() {
        let clock = ManualClock()
        var state: RestTimerState?
        #expect(makeEngine(clock: clock).tick(&state).isEmpty)
        #expect(state == nil)
    }
}
