// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — WeightEditLock, WeightEditState, WeightEditEvent,
//             WeightEditEffect, GuardedWeightEditMachine
//
// Spec §2, "Guarded weight edit (the deliberate-gesture arm)" — the
// anti-Hevy guarantee, as a two-state machine.
//
//   locked ──.longPressArm──▶ armed
//   armed  ──.longPressArm──▶ armed        (refreshes the idle deadline)
//   armed  ──3 s idle / .logSet / .doubleTap / .pageAway──▶ locked
//   locked ──.adjust──▶ locked             (no-op: weight does not move)
//
// Two rules carry the whole feature and are asserted directly:
//
// 1. **Arming is explicit.** `.longPressArm` is the only event that can
//    reach `armed`. Not adjusting, not logging, and specifically not
//    Double Tap — §2: "Double Tap … performs the primary action = Log set…
//    Never arms weight editing." `.doubleTap` therefore reports
//    `logsSet` and locks, exactly like `.logSet`.
// 2. **Idle expiry is evaluated, not scheduled.** Every `handle` first
//    checks whether the 3 s idle window has already lapsed and locks if so,
//    *before* processing the event. So a crown turn that arrives 4 s after
//    the last activity is a no-op even if nobody called `.idleTick` in
//    between — correctness does not depend on the UI's tick cadence, and a
//    process suspension cannot leave the control armed.
//
// Every lock and unlock transition emits a haptic (§2: "Every lock/unlock
// transition is a distinct haptic"), returned as `[HapticEvent]`.
//
// Imports Foundation for `Date`/`TimeInterval` only.
import Foundation

/// The two states of the weight control (§2).
public enum WeightEditLock: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Inert to taps and crown; dimmed lock glyph.
    case locked
    /// Accent colour, open lock, crown adjusts, micro-buttons visible.
    case armed
}

/// The guarded control's state: which lock state it is in, the weight it
/// holds, and when it last saw activity while armed.
///
/// A pure value, so the UI can hold it in `@State` and tests can assert on
/// it. Deliberately *not* persisted with the session: after a crash or
/// relaunch the control must come back `locked`, which is what a freshly
/// constructed value already is.
public struct WeightEditState: Sendable, Equatable, Hashable, Codable {
    public private(set) var lock: WeightEditLock

    /// Canonical kg, same guarantee as `SetRecordData.weightKg`: settable
    /// only through `Weight`, and — since `weight` below reconstructs a
    /// `Weight` from it on every read — never permitted to hold a value
    /// `Weight(kg:)` would trap on. Both mutators below enforce that, and
    /// so does the custom decoder (m1-06 review round D).
    public private(set) var weightKg: Double

    /// Instant of the last activity while armed; `nil` when locked. The
    /// 3 s auto-lock is measured from here.
    public private(set) var lastActivityAt: Date?

    public init(weight: Weight = .bodyweight) {
        self.lock = .locked
        self.weightKg = weight.kg
        self.lastActivityAt = nil
    }

    public var weight: Weight { Weight(kg: weightKg) }

    public var isArmed: Bool { lock == .armed }

    /// Replaces the weight without touching the lock — for the prefill
    /// (§2 input model) landing a new value when the lifter pages to the
    /// next set. Prefilling is not an edit, so it neither arms the control
    /// nor refreshes the idle deadline.
    public mutating func prefill(_ weight: Weight) {
        setWeightKg(weight.kg)
    }

    fileprivate mutating func setLock(_ value: WeightEditLock) { lock = value }

    /// The one write to `weightKg`, so the stored value can never leave the
    /// range `weight` is able to read back (m1-06 review round D).
    ///
    /// Negative clamps to zero: a crown turn below bodyweight is a real
    /// gesture with an obvious floor, so §2's UX is "the number stops at 0",
    /// not "the adjustment is refused". A **non-finite** proposal is
    /// different in kind — it is not a weight the lifter could have been
    /// reaching for, it is arithmetic that escaped (`increment` near
    /// `.greatestFiniteMagnitude`, or a step count large enough to overflow)
    /// — so it is refused outright and the weight simply does not move.
    /// Clamping it instead would silently substitute 0 kg or a made-up
    /// ceiling for a value the lifter never asked for, and storing it would
    /// hand the next `state.weight` read a `Weight(kg:)` trap.
    fileprivate mutating func setWeightKg(_ value: Double) {
        guard value.isFinite else { return }
        weightKg = Swift.max(0, value)
    }

    fileprivate mutating func setLastActivityAt(_ value: Date?) { lastActivityAt = value }

    private enum CodingKeys: String, CodingKey {
        case lock, weightKg, lastActivityAt
    }

    /// Custom decoder (m1-06 review round D), for the same reason `Weight`,
    /// `SetRecordData`, and `SetSnapshot` have one: synthesized `Decodable`
    /// would write a bare `Double` straight into `weightKg`, past the
    /// "settable only through `Weight`" guarantee the property claims above.
    /// A payload carrying `"weightKg": -1` would decode cleanly and then
    /// trap on the *next* `state.weight` read — a crash at a site with no
    /// visible connection to the decode that caused it. Validating here
    /// makes the hostile payload fail at the boundary it arrived through.
    /// `encode(to:)` stays synthesized; the `CodingKeys` above pin the same
    /// wire shape the type has always had.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lock = try container.decode(WeightEditLock.self, forKey: .lock)
        let rawKg = try container.decode(Double.self, forKey: .weightKg)
        do {
            weightKg = try Weight(validatingKg: rawKg).kg
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .weightKg,
                in: container,
                debugDescription: "weightKg must be a finite, non-negative number (decoded \(rawKg))."
            )
        }
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
    }
}

/// Everything that can reach the weight control (§2).
public enum WeightEditEvent: Sendable, Equatable, Hashable {
    /// The ≈0.5 s long press on the weight value — the *only* way to arm.
    case longPressArm

    /// Crown detent or a +/− micro-button, in increments. Ignored while
    /// locked (that is the whole point of the feature).
    case adjust(steps: Int)

    /// The primary "Log set" button.
    case logSet

    /// Double Tap (S9+/Series 11): the primary action, i.e. log the set.
    /// Never arms.
    case doubleTap

    /// The pager moved to another exercise.
    case pageAway

    /// A no-input evaluation, driven by the 1 Hz `TimelineView`, so the
    /// auto-lock haptic fires at the 3 s mark rather than waiting for the
    /// next real input.
    case idleTick
}

/// What handling an event implies for the caller.
public struct WeightEditEffect: Sendable, Equatable {
    /// Haptics to play, in order.
    public var haptics: [HapticEvent]

    /// The event asks for the set to be logged (`.logSet`, `.doubleTap`).
    /// The machine does not log — `SessionEngine` does.
    public var logsSet: Bool

    /// The weight actually moved (false for every ignored adjust).
    public var weightChanged: Bool

    public init(
        haptics: [HapticEvent] = [],
        logsSet: Bool = false,
        weightChanged: Bool = false
    ) {
        self.haptics = haptics
        self.logsSet = logsSet
        self.weightChanged = weightChanged
    }
}

/// The §2 guarded-edit rules, applied to an externally-stored
/// `WeightEditState`. Stateless, with an injected clock, for the same
/// reason as `RestTimerEngine`.
public struct GuardedWeightEditMachine: Sendable {
    public struct Configuration: Sendable, Equatable, Hashable {
        /// §2: "Auto-lock: 3 s of inactivity".
        public var idleTimeout: TimeInterval

        /// §2: "crown adjusts in configurable increments (default 2.5 lb /
        /// 1.25 kg equivalent)". 1.25 kg is the canonical value; the two
        /// are the same plate in the two unit systems, not a conversion of
        /// each other, so kg is stored exactly.
        public var increment: Weight

        public init(
            idleTimeout: TimeInterval = 3,
            increment: Weight = Weight(kg: 1.25)
        ) {
            self.idleTimeout = idleTimeout
            self.increment = increment
        }
    }

    public var configuration: Configuration
    public let clock: any WallClock

    public init(
        configuration: Configuration = Configuration(),
        clock: any WallClock = SystemWallClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Seconds until the armed control auto-locks; `nil` while locked.
    ///
    /// Clamped into `0...idleTimeout`: a wall clock that ran *backwards*
    /// (NTP correction, manual date change) would otherwise report an
    /// arm that lives for hours. See `applyIdleExpiry` — the next event to
    /// touch the state re-anchors it, and this read agrees with that in
    /// advance rather than promising a window the machine will not honour.
    public func timeUntilAutoLock(_ state: WeightEditState) -> TimeInterval? {
        guard state.lock == .armed, let last = state.lastActivityAt else { return nil }
        let idle = Swift.max(0, clock.now.timeIntervalSince(last))
        return Swift.max(0, configuration.idleTimeout - idle)
    }

    @discardableResult
    public func handle(_ event: WeightEditEvent, _ state: inout WeightEditState) -> WeightEditEffect {
        let now = clock.now
        var effect = WeightEditEffect()

        // Rule 2: expire a stale arm before anything else looks at the
        // state, so no event can act on an arm that should already be gone.
        if applyIdleExpiry(&state, now: now) {
            effect.haptics.append(.weightEditLocked)
        }

        switch event {
        case .longPressArm:
            if state.lock == .locked {
                state.setLock(.armed)
                effect.haptics.append(.weightEditArmed)
            }
            // Re-pressing while armed is not a second unlock — no haptic,
            // just a refreshed idle deadline.
            state.setLastActivityAt(now)

        case .adjust(let steps):
            guard state.lock == .armed else {
                // §2: "Weight is inert to taps and crown while locked."
                // An accidental crown brush or sleeve tap ends here.
                break
            }
            guard steps != 0 else {
                state.setLastActivityAt(now)
                break
            }
            let before = state.weightKg
            // Arithmetic on two *valid* inputs can still leave the range a
            // weight lives in — a configured `increment` near
            // `.greatestFiniteMagnitude` overflows to infinity in one
            // detent. `setWeightKg` refuses that rather than storing it, so
            // the control reads as "the crown did nothing" (no haptic-worthy
            // change, `weightChanged == false`) instead of poisoning the
            // next `state.weight` read.
            state.setWeightKg(before + Double(steps) * configuration.increment.kg)
            state.setLastActivityAt(now)
            effect.weightChanged = state.weightKg != before

        case .logSet, .doubleTap:
            // §2: logging auto-locks. Double Tap takes exactly this path —
            // it can log, and it can lock, but there is no branch here that
            // can arm.
            if lock(&state) {
                effect.haptics.append(.weightEditLocked)
            }
            effect.logsSet = true

        case .pageAway:
            if lock(&state) {
                effect.haptics.append(.weightEditLocked)
            }

        case .idleTick:
            // Handled entirely by the expiry above.
            break
        }

        return effect
    }

    /// Locks the control, reporting whether that was a transition.
    private func lock(_ state: inout WeightEditState) -> Bool {
        guard state.lock == .armed else { return false }
        state.setLock(.locked)
        state.setLastActivityAt(nil)
        return true
    }

    /// Locks if the idle window has lapsed; reports whether it did.
    ///
    /// A wall clock can move backwards — NTP correcting a drifted watch, or
    /// the lifter changing the date — and `lastActivityAt` is a wall-clock
    /// instant, so an arm can find itself stamped in the future. Left alone
    /// that arms the control for however far back the clock jumped, which
    /// is precisely the accidental-edit window §2 exists to close. So a
    /// future anchor is re-anchored to `now` on sight: the arm is not
    /// cancelled (the lifter did just arm it), it simply restarts its 3 s
    /// from the instant the machine noticed.
    private func applyIdleExpiry(_ state: inout WeightEditState, now: Date) -> Bool {
        guard state.lock == .armed, let last = state.lastActivityAt else { return false }
        guard now >= last else {
            state.setLastActivityAt(now)
            return false
        }
        guard now.timeIntervalSince(last) >= configuration.idleTimeout else { return false }
        state.setLock(.locked)
        state.setLastActivityAt(nil)
        return true
    }
}
