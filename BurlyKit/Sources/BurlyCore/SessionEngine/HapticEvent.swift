// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — HapticEvent, HapticLog
//
// The haptics abstraction the spec's acceptance criteria assert against
// (§2 #2 "haptic transition events", §3 #4 "haptic events fired through
// the haptics abstraction are asserted in unit tests").
//
// The abstraction is deliberately a *value*, not a player protocol:
// every engine operation in SessionEngine/ returns the haptics it would
// fire as `[HapticEvent]`, and the watch layer (m2-03+) maps each case
// onto a `WKInterfaceDevice.play(_:)` type. That keeps BurlyCore
// framework-free, keeps the engines pure (no side effects to stub), and
// makes "which haptic fired, in what order" a plain `#expect` on an array.
// `HapticLog` is the accumulator for callers that want the running
// emitted-events log rather than handling each return value.
//
// Only the events the frozen spec actually names exist here. §2: a
// distinct haptic on arm and on *every* lock/unlock transition, and a
// success haptic on logging a set. §3: a distinct pattern at the 0 mark,
// repeated once at +5 s if the screen never woke, plus an optional 10 s
// warning. Adjusting or skipping the rest timer fires nothing — the spec
// does not ask for it, so this enum does not invent it.
//
// No Foundation import needed.

/// A haptic the watch should play, named by meaning rather than by
/// waveform. Raw values are stable strings so a log can be recorded.
public enum HapticEvent: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The guarded weight control just unlocked (§2, long-press arm).
    case weightEditArmed

    /// The guarded weight control just re-locked — 3 s idle, logging a
    /// set, or paging away (§2).
    case weightEditLocked

    /// A set was written (§2, "success haptic").
    case setLogged

    /// Optional 10 s rest-timer warning (§3, setting, default on).
    case restTimerWarning

    /// The rest timer reached 0 (§3, "distinct pattern at 0").
    case restTimerFinished

    /// The one repeat of the 0-mark pattern at +5 s, fired only when the
    /// screen never woke during the rest (§3, "missable on route").
    case restTimerFinishedRepeat
}

/// An append-only log of emitted haptics.
///
/// The engines return `[HapticEvent]` from every operation; a caller (the
/// watch's haptic player, or a test) folds those returns into one of these
/// so the whole session's haptic history is a single assertable value.
public struct HapticLog: Sendable, Equatable {
    public private(set) var events: [HapticEvent]

    public init(_ events: [HapticEvent] = []) {
        self.events = events
    }

    public mutating func record(_ event: HapticEvent) {
        events.append(event)
    }

    public mutating func record(contentsOf newEvents: [HapticEvent]) {
        events.append(contentsOf: newEvents)
    }

    /// Returns everything recorded so far and empties the log — for a
    /// player that has just handed the batch to the device.
    public mutating func drain() -> [HapticEvent] {
        defer { events = [] }
        return events
    }

    public var last: HapticEvent? { events.last }

    public var isEmpty: Bool { events.isEmpty }

    public func count(of event: HapticEvent) -> Int {
        events.filter { $0 == event }.count
    }
}
