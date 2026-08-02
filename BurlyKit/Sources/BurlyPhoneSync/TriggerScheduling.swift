// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — TriggerScheduling
//
// The one thing in this module that is allowed to "wait": a minimal,
// injectable stand-in for `Task.sleep`. House rule: injected clock/scheduler
// everywhere, no `Timer` or bare `Date()` in logic. `QuietPeriodCoalescer`
// (the 5 s catalog-edit debounce and the digest-publish coalescer, spec §5)
// is the only consumer — everything else in this module that needs "now" is
// handed a `Date` explicitly by its caller instead.
//
// Production drives real wall-clock time through `Task.sleep`; tests drive a
// `ManualTriggerScheduler` that only advances when the test says so, so
// debounce behavior is asserted deterministically with no real sleeping, no
// flakiness, and no dependency on wall-clock scheduling jitter.
//
// Imports Foundation only for the standard library's `Duration` type, which
// lives there on Darwin.
import Foundation

/// A source of cooperative delay. Conformances must be `Sendable`: the
/// coalescer that holds one is an actor, and the scheduler crosses into
/// whatever `Task` the coalescer spawns to wait on it.
public protocol TriggerScheduling: Sendable {
    /// Suspends the calling task until `interval` has elapsed, by this
    /// scheduler's own notion of time. Honors task cancellation the way
    /// `Task.sleep` does — a cancelled sleep throws rather than returning
    /// early, so a caller can tell "the quiet period elapsed" from "this
    /// wait was cancelled out from under me."
    func sleep(for interval: Duration) async throws
}

/// The production scheduler: real wall-clock delay via `Task.sleep`.
public struct SystemTriggerScheduler: TriggerScheduling {
    public init() {}

    public func sleep(for interval: Duration) async throws {
        try await Task.sleep(for: interval)
    }
}
