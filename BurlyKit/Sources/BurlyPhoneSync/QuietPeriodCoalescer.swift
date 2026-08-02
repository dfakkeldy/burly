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
// trailing-edge debounce, not throttling. `coalesce` records the newest
// payload and (re)starts the quiet-period countdown on every call; only the
// last-started countdown's `perform` actually runs, because every countdown
// checks a shared generation counter before firing and a newer call always
// bumps it first.
import Foundation

/// Coalesces a burst of `coalesce(_:perform:)` calls into exactly one
/// `perform` invocation, carrying the *last* payload given, once
/// `quietPeriod` has elapsed with no further calls.
///
/// An actor because the generation counter and pending payload are mutable
/// state shared between whichever caller invokes `coalesce` and the
/// scheduled tasks racing to fire it.
public actor QuietPeriodCoalescer<Payload: Sendable> {
    private let scheduler: any TriggerScheduling
    private let quietPeriod: Duration

    private var pendingPayload: Payload?
    private var generation = 0

    /// Every task spawned by `coalesce`, cleared as they finish. Kept so
    /// tests can `await drain()` and know every debounce task — fired or
    /// superseded — has actually completed, not merely that a scheduler
    /// continuation resumed (which races the task body that follows it).
    private var inFlightTasks: [Task<Void, Never>] = []

    public init(scheduler: any TriggerScheduling, quietPeriod: Duration) {
        self.scheduler = scheduler
        self.quietPeriod = quietPeriod
    }

    /// Records `payload` as the latest pending one and restarts the
    /// countdown. When `quietPeriod` elapses without a newer call
    /// superseding this one, `perform` runs exactly once with the latest
    /// payload. A superseded countdown's `perform` never runs — it is not
    /// merely stale-and-overwritten, its firing is unconditionally skipped
    /// by the generation check below, so a caller never sees `perform` run
    /// with anything but the newest payload.
    public func coalesce(_ payload: Payload, perform: @escaping @Sendable (Payload) async -> Void) {
        pendingPayload = payload
        generation += 1
        let thisGeneration = generation
        let scheduler = self.scheduler
        let quietPeriod = self.quietPeriod

        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(for: quietPeriod)
            } catch {
                // Cancelled — nothing to fire; a newer call already owns
                // the generation this task would have checked against.
                return
            }
            await self?.fireIfCurrent(generation: thisGeneration, perform: perform)
        }
        inFlightTasks.append(task)
    }

    /// Awaits every debounce task spawned so far, fired or not, then clears
    /// them. Test-only in spirit (production never needs to "wait" for a
    /// fire-and-forget background publish) but harmless to call anywhere:
    /// it is just `await` on tasks that already exist.
    public func drain() async {
        let tasks = inFlightTasks
        inFlightTasks.removeAll()
        for task in tasks {
            await task.value
        }
    }

    private func fireIfCurrent(
        generation: Int,
        perform: @Sendable (Payload) async -> Void
    ) async {
        guard generation == self.generation, let payload = pendingPayload else { return }
        pendingPayload = nil
        await perform(payload)
    }
}
