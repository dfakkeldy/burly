// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 review round 1, major 6 — direct unit tests against
// `QuietPeriodCoalescer` itself (not through the coordinator): single
// pending task, cancellation actually frees a superseded countdown, and no
// two `perform` invocations from the same coalescer ever run concurrently.
import Testing
@testable import BurlyPhoneSync

@Suite("m4-04 — QuietPeriodCoalescer: major 6 (single task, no overlap)")
struct QuietPeriodCoalescerTests {

    @Test("a burst of coalesce() calls fires perform exactly once, with the LATEST payload")
    func burstFiresOnceWithLatestPayload() async throws {
        let scheduler = ManualTriggerScheduler()
        let coalescer = QuietPeriodCoalescer<Int>(scheduler: scheduler, quietPeriod: .seconds(5))
        let recorder = PayloadRecorder()

        for value in 1...5 {
            await coalescer.coalesce(value) { payload in await recorder.record(payload) }
        }

        await scheduler.settle()
        #expect(scheduler.pendingCount == 1, "the burst must settle to exactly one live pending task")

        scheduler.advance(by: .seconds(5))
        await coalescer.drain()

        let recorded = await recorder.values
        #expect(recorded == [5], "exactly one fire, carrying the newest payload — not the first, not an accumulation")
    }

    @Test("cancellation actually frees a superseded countdown rather than leaving it parked to a stale deadline")
    func supersededCountdownIsFreedNotLeftParked() async throws {
        let scheduler = ManualTriggerScheduler()
        let coalescer = QuietPeriodCoalescer<Int>(scheduler: scheduler, quietPeriod: .seconds(5))
        let recorder = PayloadRecorder()

        await coalescer.coalesce(1) { payload in await recorder.record(payload) }
        let firstID = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(3)) // t=3, before the first deadline (5)

        await coalescer.coalesce(2) { payload in await recorder.record(payload) }
        // The superseded first waiter must actually be gone — not merely
        // outnumbered — proving cancellation frees it rather than leaving
        // it registered until some later `advance` happens to reach its
        // stale deadline.
        _ = await scheduler.waitForFreshWaiter(excluding: [firstID])
        #expect(scheduler.pendingCount == 1, "the superseded waiter must be removed, not merely joined by a second one")

        scheduler.advance(by: .seconds(2)) // t=5: the FIRST deadline — must not fire
        await Task.yield()
        #expect(await recorder.values.isEmpty)

        scheduler.advance(by: .seconds(3)) // t=8: 5s after the SECOND coalesce()
        await coalescer.drain()
        #expect(await recorder.values == [2])
    }

    @Test("no two perform invocations from one coalescer ever run concurrently, even when a coalesce() arrives mid-perform")
    func noOverlappingPerformInvocations() async throws {
        let scheduler = ManualTriggerScheduler()
        let coalescer = QuietPeriodCoalescer<Int>(scheduler: scheduler, quietPeriod: .seconds(1))
        let gate = PerformGate()

        await coalescer.coalesce(1) { payload in
            await gate.enterAndWaitForRelease(payload)
        }
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))

        // Wait until `perform` has actually started its FIRST entry — not
        // merely until the scheduled Task exists.
        await gate.waitForEntry(1)

        // A coalesce() arriving WHILE `perform` is running for the first
        // payload. Pre-fix, nothing prevented a second, overlapping
        // `perform` from starting once its own countdown elapsed; post-fix,
        // `coalesce` sees `isPerforming` and does NOT schedule a new
        // countdown at all yet — it only records the rerun request, which
        // `fire()` acts on once the running `perform` returns. So there is
        // nothing for `scheduler.advance` to resolve here; the assertions
        // below check that no second `perform` has started by any means.
        await coalescer.coalesce(2) { payload in
            await gate.enterAndWaitForRelease(payload)
        }
        await scheduler.settle()
        #expect(await gate.concurrentEntries == 1, "a second perform must never start while the first is still running")
        #expect(scheduler.pendingCount == 0, "no new countdown is scheduled while a perform is in flight — only after it finishes")

        // Release the first perform. `fire()`'s own completion now sees the
        // rerun request and schedules a FRESH countdown for payload 2 —
        // advance past that one too before draining.
        await gate.release()
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await gate.waitForEntry(2)
        #expect(await gate.concurrentEntries == 1, "the rerun's perform must not overlap anything either")
        await gate.release()
        await coalescer.drain()

        #expect(await gate.maxObservedConcurrency == 1, "no overlap was ever observed across the whole sequence")
        #expect(await gate.completedPayloads == [1, 2])
    }

    @Test("drain() awaits a rerun chain to full completion, not just the first fire")
    func drainAwaitsARerunChainCompletely() async throws {
        let scheduler = ManualTriggerScheduler()
        let coalescer = QuietPeriodCoalescer<Int>(scheduler: scheduler, quietPeriod: .seconds(1))
        let gate = PerformGate()

        await coalescer.coalesce(1) { payload in await gate.enterAndWaitForRelease(payload) }
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await gate.waitForEntry(1)

        await coalescer.coalesce(2) { payload in await gate.enterAndWaitForRelease(payload) }

        // Release the first perform (unblocking it), then drive the rerun's
        // countdown and release it too — all from a background task running
        // concurrently with the `drain()` below, which must not return
        // early after only the first `perform` completes; it has to also
        // wait through the second, rescheduled fire.
        Task {
            await gate.release()
            _ = await scheduler.waitForFreshWaiter(excluding: [])
            scheduler.advance(by: .seconds(1))
            await gate.waitForEntry(2)
            await gate.release()
        }

        await coalescer.drain()
        #expect(await gate.completedPayloads == [1, 2])
    }

    // MARK: - Round 2, finding 6: wake-before-fire supersession

    @Test("round 2, finding 6 — a coalesce() landing after wake but before fire backs off rather than firing the newer payload at the OLD deadline")
    func supersessionAfterWakeBeforeFireBacksOff() async throws {
        let scheduler = ManualTriggerScheduler()
        let recorder = PayloadRecorder()
        let coalescer = QuietPeriodCoalescer<Int>(scheduler: scheduler, quietPeriod: .seconds(5))
        let gate = WakeGate()

        // Deterministically opens the exact window finding 6 closes: A's
        // sleep resolves and it enters the actor-isolated "about to fire"
        // hook, which suspends on an external signal — releasing the
        // coalescer actor's exclusivity, exactly as an unlucky real
        // executor interleaving would, so a `coalesce()` from elsewhere can
        // land and run to completion before A's own `fire` call resumes.
        await coalescer.setAfterWakeTestHookForTesting { await gate.waitForRelease() }

        await coalescer.coalesce(1) { payload in await recorder.record(payload) }
        let aWaiterID = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(5)) // A's sleep resolves; A is now parked inside the hook

        await gate.waitUntilEntered()

        // B arrives while A sits in that exact "woke, not yet fired"
        // window. The actor is free during A's suspension, so this runs to
        // completion: installs B's own token/task, and cancels A's task
        // (a no-op here — cancellation is cooperative and A's code path
        // never checks `Task.isCancelled`, matching the finding's premise
        // that cancellation alone cannot close this race).
        await coalescer.coalesce(2) { payload in await recorder.record(payload) }
        _ = await scheduler.waitForFreshWaiter(excluding: [aWaiterID])

        // B's own eventual wake must not be intercepted by the same hook.
        await coalescer.setAfterWakeTestHookForTesting(nil)

        // Release A. Pre-fix: `fire` trusted "I was told to run" and had no
        // way to notice it had been superseded — it would consume payload
        // 2 immediately, at A's OLD (already-elapsed) deadline, denying B
        // its own quiet period, and then null out `currentTask`, losing
        // the reference `drain()` needs to find B's still-sleeping task.
        // Post-fix: `fire(token:)` re-checks freshness and backs off with
        // NO side effects at all.
        await gate.release()
        await settleRealWork()

        #expect(await recorder.values.isEmpty, "A's stale fire must not have consumed B's payload at A's old deadline")
        #expect(scheduler.pendingCount == 1, "B's own countdown must still be the one live pending waiter — not dropped, not double-counted")

        // B's own full quiet period elapses next — it must still get to
        // fire, on its own schedule, exactly once.
        scheduler.advance(by: .seconds(5))
        await coalescer.drain()

        #expect(await recorder.values == [2], "B fires exactly once, with its own payload, after its own full quiet period")
    }
}

/// A single-entry gate a test can park a specific async call at, and later
/// release — `waitUntilEntered()` lets the test confirm the call has
/// actually reached the gate (not merely that it was invoked) before
/// proceeding, the same "wait for a real checkpoint, not a guessed delay"
/// discipline `PerformGate` above follows.
private actor WakeGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        hasEntered = true
        let waiters = enterWaiters
        enterWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PayloadRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) {
        values.append(value)
    }
}

/// A controllable `perform` body: `enterAndWaitForRelease` suspends until
/// the test calls `release()`, letting a test hold "a perform is in
/// progress" open for as long as it needs to probe for overlap.
///
/// `waitForEntry(n)` — not a plain "has anything entered" check — is what
/// makes this safe to reuse across a released-then-re-entered sequence: a
/// stale read of `concurrentEntries` transitioning 1→0 between "release"
/// and "the perform body actually decrements it" could otherwise make a
/// naive "wait until entered" check return immediately on the *first*
/// entry's tail end instead of genuinely waiting for the *second* one.
private actor PerformGate {
    private(set) var concurrentEntries = 0
    private(set) var maxObservedConcurrency = 0
    private(set) var completedPayloads: [Int] = []
    private var totalEntries = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enterAndWaitForRelease(_ payload: Int) async {
        concurrentEntries += 1
        totalEntries += 1
        maxObservedConcurrency = max(maxObservedConcurrency, concurrentEntries)
        let ready = entryWaiters.filter { $0.count <= totalEntries }
        entryWaiters.removeAll { $0.count <= totalEntries }
        for waiter in ready {
            waiter.continuation.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        concurrentEntries -= 1
        completedPayloads.append(payload)
    }

    /// Suspends until the `n`th call (1-based) to `enterAndWaitForRelease`
    /// has begun.
    func waitForEntry(_ n: Int) async {
        if totalEntries >= n { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count: n, continuation: continuation))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
