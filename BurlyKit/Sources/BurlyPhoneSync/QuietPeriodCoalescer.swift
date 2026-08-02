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
//
// ## Wake-before-fire supersession (m4-04 review round 2, finding 6)
//
// The round-1 design above still had a narrower race: a countdown's `Task`
// wakes from `scheduler.sleep`, and its next line (`Task.isCancelled` at
// the time) reads `false` — but before that task's own `await self?.fire(
// perform:)` actually reaches the actor (a plain `await` on a possibly-busy
// actor is itself a suspension point), a *fresh* `coalesce()` call can run
// to completion first: it sets `pendingPayload` to ITS OWN value, cancels
// the old task (too late — cancellation is cooperative, not preemptive; the
// old task already passed its cancellation check and is merely queued for
// the actor), and installs a brand new task. When the OLD task's queued
// `fire` call finally runs, `Task.isCancelled` is never re-checked inside
// `fire` itself — it would consume the NEW payload, immediately, at the
// OLD (already-elapsed) deadline, denying the new arrival its own quiet
// period, and then (finding no rerun requested) null out `currentTask` —
// discarding the live reference to the genuinely-current task the fresh
// `coalesce()` call just installed, which `drain()` needs to find it.
//
// The fix: `fire` no longer trusts "I was told to run" as proof that I am
// still the current countdown. Every scheduled wait carries its own opaque
// `token`; `fire(token:)` re-checks `token == currentToken` — read fresh,
// actor-isolated, at the moment it would actually consume the pending
// payload — and backs off with no side effects at all if a newer token has
// since taken over. The genuinely-current task (the one that installed that
// newer token) is always the one actually sleeping out its own full quiet
// period; a stale `fire` finding itself superseded does not need to
// "re-arm" anything — the current task already owns that job.
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
    /// The identity of whichever countdown is CURRENTLY the authoritative
    /// one (round 2, finding 6) — set every time a fresh countdown is
    /// scheduled, alongside `currentTask`. `fire(token:)` treats a mismatch
    /// between the token it was scheduled with and this value as
    /// conclusive proof it has been superseded, regardless of what
    /// `Task.isCancelled` says (cancellation is cooperative and can lose
    /// this exact race — see the file doc).
    private var currentToken: UUID?
    /// True for exactly the duration of an active `await perform(payload)`
    /// call — the re-entrancy gate a `coalesce()` arriving mid-`perform`
    /// checks before deciding whether it may start a fresh countdown itself.
    private var isPerforming = false
    /// Set when `coalesce()` arrives while `isPerforming` — `fire`'s own
    /// completion consults this to decide whether to schedule a fresh
    /// countdown for the payload that arrived meanwhile, so a coalesce
    /// during an active perform is delayed, never dropped.
    private var rerunRequested = false

    /// Test-only reentrancy hook (m4-04 review round 2, finding 6): when
    /// set, every "woke from sleep, about to fire" transition suspends
    /// here first, actor-isolated. An actor-isolated `await` on an
    /// external signal releases the actor to run other enqueued jobs —
    /// exactly the reentrancy window an unlucky executor interleaving
    /// would open in production — which is what lets a test deterministically
    /// land a `coalesce()` call from another task inside that window,
    /// rather than depending on incidental scheduling luck to reproduce a
    /// timing-sensitive race. `nil` (a no-op) in production and in every
    /// test that isn't specifically pinning this exact interleaving.
    private var afterWakeTestHook: (@Sendable () async -> Void)?

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

        // Not performing: cancel whatever is still waiting (a best-effort
        // optimization — it stops an old sleep early when the cancellation
        // wins the race — and install a fresh token identifying THIS
        // countdown as the current one. `fire(token:)`'s own check is what
        // actually guarantees correctness even when cancellation loses the
        // race (finding 6); this cancel call is not load-bearing for that,
        // only for not wasting a sleep.
        currentTask?.cancel()
        let token = UUID()
        currentToken = token
        currentTask = scheduleFire(token: token, perform: perform)
    }

    func setAfterWakeTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        afterWakeTestHook = hook
    }

    /// Internal test seam (round 3, §6): the currently-installed countdown
    /// task. The wake-before-fire pin captures countdown A's handle here
    /// *before* the superseding `coalesce()` replaces `currentTask` with
    /// B's, then awaits `A.value` after releasing the wake gate — the
    /// deterministic "A has definitely finished its fire attempt" signal a
    /// fixed wall-clock sleep could not provide (the executor may simply
    /// not schedule A's queued `fire` inside an arbitrary window, letting
    /// a pre-fix regression pass by timing luck). Read-only; changes no
    /// production behavior.
    var currentTaskForTesting: Task<Void, Never>? { currentTask }

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

    private func scheduleFire(token: UUID, perform: @escaping @Sendable (Payload) async -> Void) -> Task<Void, Never> {
        let scheduler = self.scheduler
        let quietPeriod = self.quietPeriod
        return Task { [weak self] in
            do {
                try await scheduler.sleep(for: quietPeriod)
            } catch {
                // Cancelled by a newer `coalesce()` call — nothing to fire.
                return
            }
            // Round 2, finding 6: a test-only reentrancy window (see the
            // property's doc) — a no-op unless a test has specifically
            // armed it to pin the wake-before-fire race deterministically.
            await self?.awaitAfterWakeTestHookIfSet()
            // Deliberately NOT `guard Task.isCancelled == false else {
            // return }` here anymore — that check is exactly the one the
            // finding shows losing the race (it can read `false` and then
            // still lose ownership before `fire` reaches the actor).
            // `fire(token:)` below is the sole, authoritative freshness
            // check now, evaluated atomically with the payload consumption
            // it guards.
            await self?.fire(token: token, perform: perform)
        }
    }

    private func awaitAfterWakeTestHookIfSet() async {
        if let hook = afterWakeTestHook {
            await hook()
        }
    }

    private func fire(token: UUID, perform: @escaping @Sendable (Payload) async -> Void) async {
        // Round 2, finding 6: the authoritative freshness check, made
        // atomically with the payload consumption below rather than
        // earlier (pre-suspension) where a supersession racing this exact
        // moment could still slip through. A stale `fire` backs off with
        // NO side effects — it must not touch `pendingPayload`,
        // `currentTask`, or `currentToken`, all of which the genuinely
        // current countdown (the one holding the winning token) already
        // owns.
        guard token == currentToken else { return }

        guard let payload = pendingPayload else {
            currentTask = nil
            currentToken = nil
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
            let nextToken = UUID()
            currentToken = nextToken
            currentTask = scheduleFire(token: nextToken, perform: perform)
        } else {
            rerunRequested = false
            currentTask = nil
            currentToken = nil
        }
    }
}
