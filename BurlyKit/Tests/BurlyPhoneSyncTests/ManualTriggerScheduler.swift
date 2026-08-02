// SPDX-License-Identifier: GPL-3.0-or-later
// A `TriggerScheduling` a test drives explicitly: no real sleeping, no
// wall-clock jitter, and exact-boundary assertions (e.g. "4.9 s does not
// fire, 5.0 s does") are possible because the test controls every tick.
//
// ## Cancellation is honored (m4-04 review round 1, section 5 minor)
//
// The redesigned `QuietPeriodCoalescer` (major 6) cancels a superseded
// countdown's `Task` rather than letting it sleep to a now-irrelevant
// deadline. For that cancellation to actually free the parked continuation
// — rather than leaving it registered until some *later* `advance(by:)`
// call happens to reach its stale deadline and resumes it as if nothing
// happened — `sleep(for:)` installs a `withTaskCancellationHandler` that
// removes the waiter and resumes it with `CancellationError` the moment the
// wrapping `Task` is cancelled.
//
// This is a plain, lock-protected `final class`, not an `actor`: an actor's
// `onCancel` handler runs in a non-isolated context and would need to hop
// back onto the actor (via a detached `Task`) to touch `waiters` safely,
// which reopens exactly the async race this type exists to close (would
// the cleanup actually land before a racing `advance(by:)` call runs?). A
// lock lets the handler remove-and-resume synchronously, no hop needed.
//
// ## Why `waitUntilWaiting(count:)` / `waitForFreshWaiter` exist
//
// `QuietPeriodCoalescer.coalesce` spawns an unstructured `Task` that calls
// `sleep(for:)` — by the time `await coordinator.someTrigger()` returns,
// that task may not have reached its `sleep` call yet (Task scheduling is
// not synchronous with the call that spawned it). Calling `advance(by:)`
// before the task has registered would race it: the registration would
// compute its deadline against a `virtualNow` that has already moved past
// where the test intended. Both helpers poll (cooperatively yielding, not
// sleeping) for a condition on the waiter set, giving tests a deterministic
// synchronization point with no fixed, guessed-at yield count.
//
// `waitForFreshWaiter(excluding:)` exists specifically for the
// cancel-and-reschedule case: after a `coalesce()` call that supersedes an
// existing countdown, a plain "wait until >= 1 waiter" check could return
// while the *old*, not-yet-cleaned-up waiter is still the only one present
// — a false positive that would let a test proceed and compute a deadline
// against the wrong baseline. Waiting for a waiter *other than* the known
// prior one is unambiguous regardless of how the cancellation cleanup and
// the new registration happen to interleave.
import Foundation
import BurlyPhoneSync

final class ManualTriggerScheduler: TriggerScheduling, @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var virtualNow: Duration = .zero
    private var waiters: [Waiter] = []

    func sleep(for interval: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // `withTaskCancellationHandler`'s handler fires immediately
                // if the task is *already* cancelled when this closure
                // runs — which can happen before `id` is ever registered
                // (a `Task.cancel()` racing this very call, e.g. two
                // `coalesce()` calls with no yield between them). Without
                // this check, that immediate `onCancel` would find nothing
                // to remove, `waiters.append` below would still run, and
                // the continuation would then be parked forever with no
                // second cancellation coming to free it.
                guard Task.isCancelled == false else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = virtualNow + interval
                waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: { [self] in
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let removed = index.map { waiters.remove(at: $0) }
            lock.unlock()
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` `sleep(for:)` calls are currently
    /// parked. Use only for the *first* registration in a sequence, where
    /// there is no prior waiter a stale count could be confused with — see
    /// `waitForFreshWaiter(excluding:)` for the cancel-and-reschedule case.
    func waitUntilWaiting(count: Int) async {
        while currentWaiterIDs().count < count {
            await Task.yield()
        }
    }

    /// Suspends until a waiter other than any id in `excluding` is parked,
    /// returning its id. Use this after a `coalesce()` call that is
    /// expected to cancel a previously-known waiter and register a new one
    /// — see the file doc.
    @discardableResult
    func waitForFreshWaiter(excluding: Set<UUID>) async -> UUID {
        while true {
            if let fresh = currentWaiterIDs().subtracting(excluding).first {
                return fresh
            }
            await Task.yield()
        }
    }

    /// The ids of every currently-parked waiter — a snapshot a test can
    /// pass as `excluding` to `waitForFreshWaiter`.
    func currentWaiterIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(waiters.map(\.id))
    }

    /// Moves virtual time forward and resumes (in deadline order) every
    /// waiter whose deadline has now been reached. Resuming a continuation
    /// only *schedules* its task to run — callers that need to observe the
    /// resumed work's effects must await something that actually completes
    /// after it (e.g. `PhoneSyncCoordinator.drainPendingDebounces()`), not
    /// merely call `advance` and assert immediately. In particular: do not
    /// call `drain()` after an `advance(by:)` that was NOT expected to
    /// reach every currently-outstanding waiter's deadline — `drain()`
    /// awaits the coalescer's in-flight task unconditionally, and a waiter
    /// this `advance` left untouched will not resolve until a later call
    /// does, so `drain()` would hang.
    func advance(by interval: Duration) {
        lock.lock()
        virtualNow += interval
        let now = virtualNow
        let ready = waiters
            .filter { $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
        waiters.removeAll { $0.deadline <= now }
        lock.unlock()
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// How many `sleep(for:)` calls are currently parked — a diagnostic for
    /// tests asserting "nothing fired yet" without racing `advance`.
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    /// Resumes exactly the named waiter, regardless of its deadline — a
    /// precise, id-targeted alternative to `advance(by:)` for tests that
    /// need to force one specific timer to fire ahead of another whose
    /// nominal deadline is earlier or equal (m4-04 review round 2, finding
    /// 5: a retry and a fresh edit scheduled `catalogEditDebounce` apart
    /// from the same instant compute the IDENTICAL deadline — an exact tie
    /// on paper that real OS-level timer scheduling has no obligation to
    /// resolve in either particular order). Returns `false`, doing
    /// nothing, if no waiter with that id is currently parked.
    @discardableResult
    func resumeWaiter(id: UUID) -> Bool {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume()
        return true
    }

    /// Cooperatively yields a generous, fixed number of times — enough, in
    /// this single-process cooperative-scheduling test environment with
    /// nothing else contending, for a burst of `coalesce()` calls' `Task
    /// .cancel()`s and re-schedules to fully settle (every superseded task
    /// either never registered or has been removed by its cancellation
    /// handler). Used where a test genuinely does not care *which*
    /// intermediate task ends up being "the" pending one after a burst —
    /// only that the burst has settled to the single-pending-task
    /// invariant major 6 guarantees — as opposed to
    /// `waitForFreshWaiter(excluding:)`, which is for tests that need to
    /// distinguish a specific supersession.
    func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}
