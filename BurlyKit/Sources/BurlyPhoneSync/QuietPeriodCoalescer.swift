// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — QuietPeriodCoalescer
//
// One reusable trailing-edge debounce, generic over the payload it carries.
// Two call sites in `PhoneSyncCoordinator` need exactly this shape, and spec
// §5 says so explicitly for both:
//
// - **Catalog-edit debounce**: "on any routine/catalog edit (debounced 5 s)"
//   — a burst of edits must reach `PhoneSyncMachine` as exactly one
//   `.catalogChanged` event ("by the time this event arrives it means 'one
//   new working-set generation'", per that event's own doc).
// - **Digest-publish coalescing**: the binding contract's item 6 —
//   publications are latest-wins and individually disposable, and a burst
//   (ghost-redelivery storms, rapid confirmations) must become one
//   derivation and one `updateApplicationContext` per quiet period,
//   "mirroring the §5 5 s catalog-edit debounce."
//
// One design point both share: it is the *last* payload that must survive a
// burst, not the first, and not an accumulation of all of them — this is
// trailing-edge debounce, not throttling.
//
// ## Single pending task, no overlapping publications (m4-04 review round 1,
// major 6)
//
// The first version of this type let a superseded countdown keep sleeping
// to its original deadline — a generation counter made its eventual firing
// a no-op, but the `Task` itself lived on, accumulating one entry per
// `coalesce()` call for the lifetime of the coalescer, and nothing bounded
// how many could be genuinely *racing* `perform` concurrently if a fire and
// a fresh supersession landed close together (actor re-entrancy across
// `perform`'s own awaits). Two things fix that:
//
// - **Single pending task.** `coalesce` cancels whatever is currently
//   waiting before starting a fresh countdown, so there is never more than
//   one live "waiting to fire" task, and nothing to leak.
// - **`isPerforming` gates re-entrancy.** If a new `coalesce()` call arrives
//   while a `perform` from an earlier fire is still running, it does not
//   start a second, overlapping `perform` — it records the new payload and
//   a "rerun" flag, and the *currently running* `perform`'s own completion
//   schedules the next countdown once it returns. Two `perform` calls for
//   the same coalescer are therefore never in flight at once, and no
//   payload a caller handed in is silently dropped.
import Foundation

/// Coalesces a burst of `coalesce(_:perform:)` calls into exactly one
/// `perform` invocation, carrying the *last* payload given, once
/// `quietPeriod` has elapsed with no further calls — and never lets two
/// `perform` invocations from the same coalescer run concurrently (major 6).
///
/// An actor because the pending payload, the single in-flight task, and the
/// re-entrancy flags are mutable state shared between whichever caller
/// invokes `coalesce` and the scheduled task racing to fire it.
public actor QuietPeriodCoalescer<Payload: Sendable> {
    private let scheduler: any TriggerScheduling
    private let quietPeriod: Duration

    private var pendingPayload: Payload?
    /// The one task currently either waiting out the quiet period or
    /// running `fire` (which itself awaits `perform`) — never more than one
    /// at a time (major 6).
    private var currentTask: Task<Void, Never>?
    /// True for exactly the duration of an active `await perform(payload)`
    /// call — the re-entrancy gate a `coalesce()` arriving mid-`perform`
    /// checks before deciding whether it may start a fresh countdown itself.
    private var isPerforming = false
    /// Set when `coalesce()` arrives while `isPerforming` — `fire`'s own
    /// completion consults this to decide whether to schedule a fresh
    /// countdown for the payload that arrived meanwhile, so a coalesce
    /// during an active perform is delayed, never dropped.
    private var rerunRequested = false

    public init(scheduler: any TriggerScheduling, quietPeriod: Duration) {
        self.scheduler = scheduler
        self.quietPeriod = quietPeriod
    }

    /// Records `payload` as the latest pending one and restarts the
    /// countdown. When `quietPeriod` elapses without a newer call
    /// superseding this one, `perform` runs exactly once with the latest
    /// payload.
    ///
    /// If a `perform` from an earlier fire is still running, this does
    /// *not* start a second one — see the file doc's "single pending task"
    /// note — it just remembers to run again, with the freshest payload,
    /// once the running one finishes.
    public func coalesce(_ payload: Payload, perform: @escaping @Sendable (Payload) async -> Void) {
        pendingPayload = payload

        if isPerforming {
            rerunRequested = true
            return
        }

        // Not performing: cancel whatever is still waiting (harmless no-op
        // if it already fired or was never scheduled) and restart the
        // countdown fresh.
        currentTask?.cancel()
        currentTask = scheduleFire(perform: perform)
    }

    /// Awaits the in-flight chain — the task currently waiting to fire or
    /// actively performing, and any rerun `fire()` schedules after it — to
    /// fully settle. Test-only in spirit (production never needs to "wait"
    /// for a fire-and-forget background publish) but harmless to call
    /// anywhere.
    public func drain() async {
        while let task = currentTask {
            await task.value
            // `fire()` may have just installed a NEW `currentTask` (a
            // rerun) before this resumes; loop to also drain that, until
            // nothing remains.
        }
    }

    private func scheduleFire(perform: @escaping @Sendable (Payload) async -> Void) -> Task<Void, Never> {
        let scheduler = self.scheduler
        let quietPeriod = self.quietPeriod
        return Task { [weak self] in
            do {
                try await scheduler.sleep(for: quietPeriod)
            } catch {
                // Cancelled by a newer `coalesce()` call — nothing to fire.
                return
            }
            guard Task.isCancelled == false else { return }
            await self?.fire(perform: perform)
        }
    }

    private func fire(perform: @escaping @Sendable (Payload) async -> Void) async {
        guard let payload = pendingPayload else {
            currentTask = nil
            return
        }
        pendingPayload = nil
        isPerforming = true
        await perform(payload)
        isPerforming = false

        if rerunRequested, pendingPayload != nil {
            // A newer coalesce() arrived while `perform` was running —
            // honor it with a fresh quiet period rather than firing
            // immediately (still a debounce, restarted from "perform just
            // finished", not skipped).
            rerunRequested = false
            currentTask = scheduleFire(perform: perform)
        } else {
            rerunRequested = false
            currentTask = nil
        }
    }
}
