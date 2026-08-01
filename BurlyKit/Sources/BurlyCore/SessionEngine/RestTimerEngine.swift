// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — RestTimerState, RestTimerConfiguration, RestDuration,
//             RestTimerEngine
//
// Spec §3, complete. Three types and a namespace:
//
// - `RestDuration` — the resolution ladder and the 15 s–5 min / 15 s-step
//   clamp, as pure arithmetic.
// - `RestTimerState` — the serializable timer: a stored `endDate` plus
//   which haptics have already fired. Lives on `ActiveSession` so it
//   survives crash/resume (§3, "timer state is part of the active session
//   record").
// - `RestTimerEngine` — a *stateless* engine over `inout RestTimerState?`
//   with an injected clock. Statelessness is the point: the state is a
//   value someone else persists, and the engine is the rules that move it.
//
// ## Wall clock, not a ticking timer
//
// §3: "the timer is a stored `endDate` … process suspension, Always-On, or
// relaunch never drifts it. No `Timer` accumulation." Nothing here counts
// down. `remaining(at:)` is subtraction against the clock, and `tick()` is
// an *evaluation* — the UI calls it once a second from `TimelineView`, but
// correctness never depends on how often it is called. Every haptic
// decision is keyed off `endDate` and a fired-flag, so a clock that jumps
// forward by ten minutes (suspension, wrist down) produces exactly the same
// events, at once, that a 1 Hz caller would have produced one at a time.
//
// Imports Foundation for `Date`/`TimeInterval` only.
import Foundation

// MARK: - Duration resolution

/// §3's duration rules: `restOverride` → routine default → global 90 s,
/// clamped to 15 s–5 min in 15 s steps.
public enum RestDuration {
    /// §3 global default.
    public static let globalDefault: TimeInterval = 90
    public static let minimum: TimeInterval = 15
    public static let maximum: TimeInterval = 300
    public static let step: TimeInterval = 15

    /// The resolution ladder, then the clamp. The routine-level default is
    /// a parameter rather than a field on `RoutineData`: §1 is frozen and
    /// defines no routine rest field, so the caller (settings + routine
    /// editor, §9) supplies it.
    public static func resolve(
        itemOverride: TimeInterval?,
        routineDefault: TimeInterval? = nil,
        globalDefault: TimeInterval = RestDuration.globalDefault
    ) -> TimeInterval {
        clamped(itemOverride ?? routineDefault ?? globalDefault)
    }

    /// Rounds to the nearest 15 s step, then clamps into 15 s…5 min.
    /// Rounding happens first so that a stored 100 s becomes 105 s rather
    /// than being left off-grid, and clamping happens last so the bounds
    /// are absolute.
    public static func clamped(_ raw: TimeInterval) -> TimeInterval {
        guard raw.isFinite else { return globalDefault }
        let stepped = (raw / step).rounded() * step
        return Swift.min(maximum, Swift.max(minimum, stepped))
    }
}

// MARK: - State

/// The serializable rest timer (§3). Stored on `ActiveSession`.
///
/// `startedAt` and `endDate` are wall-clock instants; everything else is a
/// latch recording that a haptic already fired, so that replaying `tick()`
/// any number of times can never double-fire.
public struct RestTimerState: Sendable, Equatable, Hashable, Codable {
    public private(set) var startedAt: Date

    /// The one source of truth for the countdown (§3).
    public private(set) var endDate: Date

    /// True once the 10 s warning fired *or* was deliberately suppressed
    /// because the timer was already past zero when first evaluated.
    public private(set) var warningFired: Bool

    /// True once the 0-mark haptic fired.
    public private(set) var finishedFired: Bool

    /// True once the single +5 s repeat fired (or was ruled out).
    public private(set) var repeatFired: Bool

    /// Whether the screen woke at any point during this rest. §3 repeats
    /// the 0-mark pattern once at +5 s only "if screen never woke" — the
    /// scope of "never" is this timer, reset on every start.
    public private(set) var screenWoke: Bool

    public init(startedAt: Date, duration: TimeInterval) {
        self.startedAt = startedAt
        self.endDate = startedAt.addingTimeInterval(duration)
        self.warningFired = false
        self.finishedFired = false
        self.repeatFired = false
        self.screenWoke = false
    }

    /// Total rest length, i.e. `endDate - startedAt`. Moves with +15/−15.
    public var duration: TimeInterval {
        endDate.timeIntervalSince(startedAt)
    }

    /// Seconds left, floored at 0 — what the countdown ring renders.
    public func remaining(at now: Date) -> TimeInterval {
        Swift.max(0, endDate.timeIntervalSince(now))
    }

    /// Signed seconds left; negative once the timer is past zero. Used by
    /// the engine's evaluation, not by the UI.
    public func signedRemaining(at now: Date) -> TimeInterval {
        endDate.timeIntervalSince(now)
    }

    public func isFinished(at now: Date) -> Bool {
        now >= endDate
    }

    public func elapsed(at now: Date) -> TimeInterval {
        now.timeIntervalSince(startedAt)
    }

    // Mutators are fileprivate: `RestTimerEngine` is the only thing that
    // may move a timer, so the fired-latches cannot be cleared by accident.
    fileprivate mutating func setEndDate(_ date: Date) { endDate = date }
    fileprivate mutating func setWarningFired(_ value: Bool) { warningFired = value }
    fileprivate mutating func setFinishedFired(_ value: Bool) { finishedFired = value }
    fileprivate mutating func setRepeatFired(_ value: Bool) { repeatFired = value }
    fileprivate mutating func setScreenWoke(_ value: Bool) { screenWoke = value }
}

// MARK: - Configuration

/// The settings §3 exposes, plus its two fixed timings.
public struct RestTimerConfiguration: Sendable, Equatable, Hashable, Codable {
    /// §3 global default rest (settings, §9).
    public var globalDefault: TimeInterval

    /// Routine-level default, when the active routine has one. See
    /// `RestDuration.resolve` for why this is not a `RoutineData` field.
    public var routineDefault: TimeInterval?

    /// §3: "optional 10 s warning haptic (setting, default on)".
    public var warningEnabled: Bool

    /// How far out the warning fires.
    public var warningLeadTime: TimeInterval

    /// §3: the 0-mark pattern "repeats once at +5 s".
    public var missedRepeatDelay: TimeInterval

    public init(
        globalDefault: TimeInterval = RestDuration.globalDefault,
        routineDefault: TimeInterval? = nil,
        warningEnabled: Bool = true,
        warningLeadTime: TimeInterval = 10,
        missedRepeatDelay: TimeInterval = 5
    ) {
        self.globalDefault = globalDefault
        self.routineDefault = routineDefault
        self.warningEnabled = warningEnabled
        self.warningLeadTime = warningLeadTime
        self.missedRepeatDelay = missedRepeatDelay
    }
}

// MARK: - Engine

/// The §3 rules, applied to an externally-stored `RestTimerState?`.
public struct RestTimerEngine: Sendable {
    public var configuration: RestTimerConfiguration
    public let clock: any WallClock

    public init(
        configuration: RestTimerConfiguration = RestTimerConfiguration(),
        clock: any WallClock = SystemWallClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// The duration this engine would use for an exercise whose item
    /// override is `itemOverride` (§3 resolution order).
    public func resolvedDuration(itemOverride: TimeInterval?) -> TimeInterval {
        RestDuration.resolve(
            itemOverride: itemOverride,
            routineDefault: configuration.routineDefault,
            globalDefault: configuration.globalDefault
        )
    }

    /// Starts (or restarts) the rest timer.
    ///
    /// §3: auto-starts on *every* logged set, warmups included, and
    /// "logging the next set cancels any running timer and starts a fresh
    /// one" — which is precisely an unconditional overwrite, so there is no
    /// separate cancel step and no way to end up with two timers.
    @discardableResult
    public func start(
        _ state: inout RestTimerState?,
        itemOverride: TimeInterval? = nil
    ) -> RestTimerState {
        let fresh = RestTimerState(
            startedAt: clock.now,
            duration: resolvedDuration(itemOverride: itemOverride)
        )
        state = fresh
        return fresh
    }

    /// Starts with an exact duration, still clamped to the §3 grid. For
    /// callers that resolved the duration themselves.
    @discardableResult
    public func start(
        _ state: inout RestTimerState?,
        duration: TimeInterval
    ) -> RestTimerState {
        let fresh = RestTimerState(
            startedAt: clock.now,
            duration: RestDuration.clamped(duration)
        )
        state = fresh
        return fresh
    }

    /// §3's +15 s / −15 s. `delta` is added to the *total* duration, so
    /// the clamp stays on the same 15 s…5 min range the timer started in.
    ///
    /// Adjusting re-opens any latch whose condition the adjustment undid:
    /// extending a timer past the warning threshold means the warning is
    /// due again, and extending it past zero means it is running again.
    /// Returns the haptics the adjustment itself makes due (normally none;
    /// a −15 that lands past zero finishes the timer immediately).
    @discardableResult
    public func adjust(
        _ state: inout RestTimerState?,
        by delta: TimeInterval
    ) -> [HapticEvent] {
        guard var timer = state else { return [] }
        let newDuration = RestDuration.clamped(timer.duration + delta)
        timer.setEndDate(timer.startedAt.addingTimeInterval(newDuration))

        let remaining = timer.signedRemaining(at: clock.now)
        if remaining > 0 {
            timer.setFinishedFired(false)
            timer.setRepeatFired(false)
        }
        if remaining > configuration.warningLeadTime {
            timer.setWarningFired(false)
        }
        state = timer
        return evaluate(&state)
    }

    /// §3 tap-to-skip: "confirm-free; skipping is never destructive" — it
    /// clears the timer and fires nothing.
    public func skip(_ state: inout RestTimerState?) {
        state = nil
    }

    /// The screen woke during this rest, so the +5 s repeat is not needed
    /// (§3).
    public func noteScreenWake(_ state: inout RestTimerState?) {
        guard var timer = state else { return }
        timer.setScreenWoke(true)
        state = timer
    }

    /// Evaluates the timer against the clock and returns any haptics now
    /// due. Idempotent: calling it twice at the same instant, or once after
    /// a long suspension, produces each haptic exactly once.
    @discardableResult
    public func tick(_ state: inout RestTimerState?) -> [HapticEvent] {
        evaluate(&state)
    }

    public func remaining(_ state: RestTimerState?) -> TimeInterval {
        state?.remaining(at: clock.now) ?? 0
    }

    public func isRunning(_ state: RestTimerState?) -> Bool {
        guard let state else { return false }
        return !state.isFinished(at: clock.now)
    }

    // MARK: - Evaluation

    private func evaluate(_ state: inout RestTimerState?) -> [HapticEvent] {
        guard var timer = state else { return [] }
        let now = clock.now
        let remaining = timer.signedRemaining(at: now)
        var haptics: [HapticEvent] = []

        if remaining > 0 {
            if configuration.warningEnabled,
               !timer.warningFired,
               remaining <= configuration.warningLeadTime {
                timer.setWarningFired(true)
                haptics.append(.restTimerWarning)
            }
        } else {
            // Past zero. A warning is no longer meaningful — latch it
            // without firing, so a clock that jumped straight through the
            // window (suspension, Always-On) never buzzes a "10 s left"
            // for a rest that is already over.
            timer.setWarningFired(true)

            if !timer.finishedFired {
                timer.setFinishedFired(true)
                haptics.append(.restTimerFinished)
            }

            if !timer.repeatFired,
               now >= timer.endDate.addingTimeInterval(configuration.missedRepeatDelay) {
                timer.setRepeatFired(true)
                // Latched either way: the repeat window is past, so it can
                // never fire later. It only *sounds* if the screen stayed
                // dark for the whole rest.
                if !timer.screenWoke {
                    haptics.append(.restTimerFinishedRepeat)
                }
            }
        }

        state = timer
        return haptics
    }
}
