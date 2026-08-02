// SPDX-License-Identifier: GPL-3.0-or-later
// A `TriggerScheduling` a test drives explicitly: no real sleeping, no
// wall-clock jitter, and exact-boundary assertions (e.g. "4.9 s does not
// fire, 5.0 s does") are possible because the test controls every tick.
//
// ## Why `waitUntilWaiting(count:)` exists
//
// `QuietPeriodCoalescer.coalesce` spawns an unstructured `Task` that calls
// `sleep(for:)` — by the time `await coordinator.someTrigger()` returns, that
// task may not have reached its `sleep` call yet (Task scheduling is not
// synchronous with the call that spawned it). Calling `advance(by:)` before
// the task has registered would race it: the registration would compute its
// deadline against a `virtualNow` that has already moved past where the test
// intended. `waitUntilWaiting(count:)` polls (cooperatively yielding, not
// sleeping) until the expected number of `sleep` calls are actually parked,
// giving tests a deterministic synchronization point with no fixed,
// guessed-at yield count.
import BurlyPhoneSync

actor ManualTriggerScheduler: TriggerScheduling {
    private var virtualNow: Duration = .zero
    private var waiters: [(deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = []

    func sleep(for interval: Duration) async throws {
        let deadline = virtualNow + interval
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((deadline: deadline, continuation: continuation))
        }
    }

    /// Suspends until at least `count` `sleep(for:)` calls are currently
    /// parked. Call this before `advance(by:)` whenever the number of
    /// `coalesce()` calls a test just made is known.
    func waitUntilWaiting(count: Int) async {
        while waiters.count < count {
            await Task.yield()
        }
    }

    /// Moves virtual time forward and resumes (in deadline order) every
    /// waiter whose deadline has now been reached. Resuming a continuation
    /// only *schedules* its task to run — callers that need to observe the
    /// resumed work's effects must await something that actually completes
    /// after it (e.g. `PhoneSyncCoordinator.drainPendingDebounces()`), not
    /// merely call `advance` and assert immediately.
    func advance(by interval: Duration) {
        virtualNow += interval
        let ready = waiters
            .filter { $0.deadline <= virtualNow }
            .sorted { $0.deadline < $1.deadline }
        waiters.removeAll { $0.deadline <= virtualNow }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// How many `sleep(for:)` calls are currently parked — a diagnostic for
    /// tests asserting "nothing fired yet" without racing `advance`.
    var pendingCount: Int {
        get async { waiters.count }
    }
}
