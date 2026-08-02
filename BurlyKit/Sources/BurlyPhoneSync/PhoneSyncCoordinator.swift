// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — PhoneSyncCoordinator
//
// The phone-side session ingest executor and push-trigger runtime
// `SyncMachineBinding.swift`'s BINDING CONTRACT describes.
//
// ## Why `@MainActor`, not a standalone `actor`
//
// `BurlyStore` and `SwiftDataStore` are themselves `@MainActor`-isolated
// (m4-04 review round 1, blocker 2) — the store's own doc explains why:
// "create and use a store from one isolation domain," now compiler-enforced
// rather than merely stated. This type is `@MainActor` for the same reason:
// isolating it to its own custom `actor` would give the sync half of the
// app a second isolation domain over a store the *rest* of the app (§6's
// editor, §9's catalog browser) is expected to touch from `@MainActor` —
// exactly the hazard the store's doc calls out, just moved one level up.
// `@MainActor` here means every store mutation in the app funnels through
// the one executor the whole platform already schedules UI and most app
// logic on, satisfying binding contract item 1 as an app-wide property.
//
// ## Command execution, one contract item at a time
//
// - **Item 1 (single executor):** every `case` in `executeOne` runs on the
//   main actor, *and* `execute(_:originalPayload:)` — the entry point every
//   top-level trigger and ingest call goes through — holds an explicit
//   execution lock around the whole batch (see "Major 4" below): `@MainActor`
//   isolation alone prevents two calls from running literally
//   simultaneously, but it does **not** prevent one call's command batch
//   from *interleaving* with another's across an `await` inside it (actor
//   re-entrancy) — the lock is what closes that gap for command batches
//   specifically. `QuietPeriodCoalescer` is a *separate* actor (it owns only
//   sleep/re-entrancy bookkeeping, never the store), but every closure it
//   calls back into only ever does `await self.method()` on this
//   `@MainActor` type — the actual store work always hops back onto the
//   main actor, through the same lock, before it happens.
// - **Item 2 (conditional write):** `.applySessionUpsert` calls
//   `BurlyStore.applyReplicatedSession(_:upsertingPlaceholderExercises:)`,
//   which rechecks the stored revision *inside* its own transaction (see
//   that method's doc) — this runtime never recomputes or re-trusts the
//   advisory `storedRevision` the event carried.
// - **Item 3 (confirm only after durability, at most once):** a thrown
//   `applyIncomingSession` is caught right there and nothing further
//   happens for that command — no `.sessionStoreConfirmed`, so no ack, no
//   publish. The machine's own pending-confirmation bookkeeping (its file
//   doc) is what makes "at most once" and "causally correlated" hold; this
//   runtime just never sends the event when the store didn't durably
//   commit.
// - **Item 4 (failed verification re-drives):** `.confirmSessionStored`
//   re-reads the store fresh and, if it no longer proves the revision,
//   feeds `originalPayload` back through `.sessionReceived` with the
//   *current* observed revision — never confirms from the stale decision.
// - **Item 5 (state persists with the ack):** `deliver(_:)` calls
//   `machine.handle` and persists the resulting state *before* returning
//   the commands for execution — so a crash between "ack recorded" and
//   "digest published" always finds the ack already durable, and the next
//   event that produces a `publishDigest` command re-covers it.
//   `PhoneSyncStatePersisting`'s conformer also durably records the
//   monotonic snapshot identities *before* the primary state save (blocker
//   1) — see that protocol's doc.
// - **Item 6 (digest publications coalesce, and carry only a signal):**
//   `.publishDigest`'s execution goes through `digestCoalescer` — a burst of
//   confirmations/history-changed signals becomes one derivation and one
//   transport call. m4-04 review round 1, major 5: the coalesced payload is
//   `Void`, not the command's `(snapshotVersion, ackedSessionIDs)` — those
//   are read from `self.state` at *fire* time (`publishDigestNow`), not
//   captured when the burst started, so a catalog edit or a later ack that
//   lands mid-quiet-period is never published stale.
//
// ## Major 3 — a trigger's "done" state is only set after success
//
// `dailyPushIfDue` and `watchAppInstalledDidChange`'s edge-trigger both
// suppress future firing once they believe they've pushed. The first
// version of both marked that suppression *before* the push had actually
// gone anywhere, so a failure (a store read building the snapshot, a
// transport that couldn't enqueue) silently ate the only signal that would
// have retried it — the daily push would not fire again for a full day, and
// a failed install-flip push required an actual uninstall-reinstall cycle
// to ever retry. Both now mark done only after `runEvent` returns
// successfully, and the install-flip path remembers a failure explicitly
// (`pendingInstallPushRetry`) so the *next* edge-shaped call retries it
// rather than treating "already installed" as "nothing to do." Catalog-edit
// failures are handled differently — see `deliverCatalogChanged`'s doc —
// because that trigger has no later edge to re-arm it on.
import Foundation
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncMachine

@MainActor
public final class PhoneSyncCoordinator {
    public struct Configuration: Sendable {
        /// §5: "on any routine/catalog edit (debounced 5 s)".
        public var catalogEditDebounce: Duration
        /// Binding contract item 6: "mirroring the §5 5 s catalog-edit
        /// debounce" — the digest-publish coalescing window.
        public var digestPublishDebounce: Duration
        /// §5's daily push, expressed as a minimum interval since the last
        /// one rather than a wall-clock time-of-day (no calendar/timezone
        /// policy is specified, and a minimum interval is trivially
        /// testable under an injected clock).
        public var dailyPushInterval: TimeInterval
        /// How many extra attempts a failed catalog-edit push gets (major
        /// 3), each spaced by `catalogEditDebounce`, before giving up and
        /// leaving the failure surfaced on `lastCatalogPushFailure` for the
        /// next genuine edit to retry instead.
        public var catalogPushRetryCount: Int

        public init(
            catalogEditDebounce: Duration = .seconds(5),
            digestPublishDebounce: Duration = .seconds(5),
            dailyPushInterval: TimeInterval = 24 * 60 * 60,
            catalogPushRetryCount: Int = 2
        ) {
            self.catalogEditDebounce = catalogEditDebounce
            self.digestPublishDebounce = digestPublishDebounce
            self.dailyPushInterval = dailyPushInterval
            self.catalogPushRetryCount = catalogPushRetryCount
        }
    }

    private let store: any BurlyStore
    private let transport: any PhoneSyncTransporting
    private let digestPublisher: any PhoneDigestPublishing
    private let statePersisting: any PhoneSyncStatePersisting
    private let clock: any WallClock
    private let scheduler: any TriggerScheduling
    private let machine: BurlyPhoneSyncMachine
    private let configuration: Configuration

    private var state: BurlyPhoneSyncMachine.State
    private var lastDailyPushAt: Date?
    private var isWatchAppInstalled = false
    /// Major 3: set when an install-flip push fails, so the *next* call —
    /// even a redundant `true` that would otherwise be a no-op — retries it
    /// instead of treating "already installed" as "already pushed."
    private var pendingInstallPushRetry = false
    /// Major 3, surfaced (not merely retried): the most recent catalog-edit
    /// push failure, or `nil` once one has succeeded. Public so a host app
    /// can observe and log/report it; the retry loop in
    /// `deliverCatalogChanged` also acts on it independently.
    public private(set) var lastCatalogPushFailure: (any Error)?
    /// Blocker 1: `true` when `init` had to reconstruct state from the
    /// high-water-mark log alone because the primary sidecar was
    /// missing/unreadable/semantically invalid — a surfaced recovery event,
    /// not a silent reset. See `PhoneSyncStatePersisting`'s doc.
    public private(set) var recoveredFromCorruptState = false

    private let catalogDebouncer: QuietPeriodCoalescer<Void>
    private let digestCoalescer: QuietPeriodCoalescer<Void>

    // MARK: - Execution lock (major 4)
    //
    // `@MainActor` isolation guarantees no two calls into this type run
    // literally simultaneously, but it does not stop one call's command
    // batch from *interleaving* with another's at an `await` inside it
    // (actor re-entrancy): Push A can suspend mid-batch (awaiting the
    // transport's cancel call) and let Push B's entire batch run to
    // completion before A resumes, which is exactly the "two transfers end
    // up active" race the review's major 4 traces through cancel/transmit
    // pairs. This lock makes one command batch (`execute(_:originalPayload:)`
    // and everything it does, including its own internal confirm→publish
    // recursion) run to completion — however many `await`s it contains —
    // before the next one is allowed to start its own transport calls.
    //
    // A plain wait-queue of continuations, not a `Task` chain: simpler to
    // reason about (FIFO order is just "append, then wait to be resumed"),
    // and ownership transfers directly from `releaseExecutionLock` to the
    // next waiter without ever setting `isExecuting` back to `false` in
    // between, so there is no window where a third call could slip in.
    private var isExecuting = false
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: any BurlyStore,
        transport: any PhoneSyncTransporting,
        digestPublisher: any PhoneDigestPublishing,
        statePersisting: any PhoneSyncStatePersisting,
        clock: any WallClock = SystemWallClock(),
        scheduler: any TriggerScheduling = SystemTriggerScheduler(),
        machineConfiguration: BurlyPhoneSyncMachine.Configuration = BurlyPhoneSyncMachine.Configuration(),
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.transport = transport
        self.digestPublisher = digestPublisher
        self.statePersisting = statePersisting
        self.clock = clock
        self.scheduler = scheduler
        self.machine = BurlyPhoneSyncMachine(configuration: machineConfiguration)
        self.configuration = configuration

        // Blocker 1: `load()` itself no longer silently resets a monotonic
        // identity — see `PhoneSyncStatePersisting`'s doc. A `load()` call
        // that throws outright (as opposed to returning a
        // `recoveredFromCorruption: true` result) is a harder failure than
        // "the primary file was corrupt" — e.g. the high-water log's own
        // directory is unreadable — and is treated the same way: fail-safe,
        // still surfaced.
        do {
            if let result = try statePersisting.load() {
                self.state = result.runtimeState.machineState
                self.lastDailyPushAt = result.runtimeState.lastDailyPushAt
                self.recoveredFromCorruptState = result.recoveredFromCorruption
            } else {
                self.state = BurlyPhoneSyncMachine.State()
                self.lastDailyPushAt = nil
            }
        } catch {
            self.state = BurlyPhoneSyncMachine.State()
            self.lastDailyPushAt = nil
            self.recoveredFromCorruptState = true
        }

        self.catalogDebouncer = QuietPeriodCoalescer(
            scheduler: scheduler,
            quietPeriod: configuration.catalogEditDebounce
        )
        self.digestCoalescer = QuietPeriodCoalescer(
            scheduler: scheduler,
            quietPeriod: configuration.digestPublishDebounce
        )
    }

    // MARK: - Session ingest (binding contract items 1–5)

    /// A §5 `session` payload arrived from the watch. Looks up the store's
    /// current revision for this id (`nil` when not stored — the advisory
    /// lookup `PhoneSyncMachine.Event.sessionReceived`'s doc describes),
    /// routes it through the machine, and executes whatever it decides.
    public func sessionReceived(_ payload: BurlySessionPayloadDTO) async throws {
        let storedRevision = try store.session(id: payload.session.id)?.revision
        let commands = try deliver(.sessionReceived(payload, storedRevision: storedRevision))
        try await execute(commands, originalPayload: payload)
    }

    // MARK: - Push triggers (§5)

    /// §5: "snapshot on app launch". Unconditional — the machine's own
    /// `.snapshotPushTriggered` handling cancels-and-resends the current
    /// version regardless of whether anything is already outstanding (see
    /// that event's doc for why an unconditional resend is the liveness-
    /// correct choice).
    public func applicationDidLaunch() async throws {
        try await runEvent(.snapshotPushTriggered)
    }

    /// §5: "when `isWatchAppInstalled` flips true". Edge-triggered on the
    /// false→true transition — a redundant `true` (already installed) or a
    /// `false` never pushes anything on their own — **except** major 3's
    /// retry case: if the last edge-triggered push failed,
    /// `pendingInstallPushRetry` makes the *next* `true` (redundant or not)
    /// try again, since the original edge is otherwise gone forever once
    /// `isWatchAppInstalled` is already `true`.
    public func watchAppInstalledDidChange(_ isInstalled: Bool) async throws {
        let wasInstalled = isWatchAppInstalled
        isWatchAppInstalled = isInstalled
        guard isInstalled else {
            pendingInstallPushRetry = false
            return
        }
        guard wasInstalled == false || pendingInstallPushRetry else { return }
        do {
            try await runEvent(.snapshotPushTriggered)
            pendingInstallPushRetry = false
        } catch {
            pendingInstallPushRetry = true
            throw error
        }
    }

    /// §5: "and daily." Expressed as "due" against `configuration
    /// .dailyPushInterval` since the last fire (persisted — see
    /// `PhoneSyncStatePersisting`) rather than an owned sleep loop: a real
    /// app has no guaranteed continuously-running process to host a 24 h
    /// `Task.sleep`, and every realistic trigger for checking this (app
    /// launch, a scene becoming active, a background-refresh task) is
    /// already an *opportunity* to check "is it due", not a moment that
    /// needs its own timer. Callers are expected to call this from
    /// whichever of those moments the host app wires up; calling it more
    /// often than the interval is free (it just observes "not due" and
    /// returns).
    ///
    /// Major 3: `lastDailyPushAt` is only advanced *after* `runEvent`
    /// succeeds — a failed push (a store read, a transport enqueue) must
    /// not suppress the next 24 h of attempts on top of the failure itself.
    public func dailyPushIfDue() async throws {
        let now = clock.now
        if let last = lastDailyPushAt, now.timeIntervalSince(last) < configuration.dailyPushInterval {
            return
        }
        try await runEvent(.snapshotPushTriggered)
        lastDailyPushAt = now
        try persistRuntimeState()
    }

    /// §5: "on any routine/catalog edit (debounced 5 s)". Call this once
    /// per edit; a burst within the quiet period collapses into exactly one
    /// `.catalogChanged` event — see `catalogDebouncer` and
    /// `deliverCatalogChanged`'s doc for what happens if the push that
    /// results from it fails.
    public func catalogDidChange() async {
        await catalogDebouncer.coalesce(()) { [weak self] _ in
            await self?.deliverCatalogChanged()
        }
    }

    /// §5: "Digest is refreshed whenever history changes (a session arrives
    /// or is edited)". Every call reaches the machine (`.historyChanged`
    /// carries no state of its own to accumulate), but the resulting
    /// `publishDigest` *execution* is coalesced exactly like a burst of
    /// confirmations would be.
    public func historyDidChange() async throws {
        try await runEvent(.historyChanged)
    }

    /// The transport's completion (or failure) callback for a snapshot
    /// transfer, echoing the `(version, generation)` identity
    /// `.transmitSnapshot` started it with.
    public func snapshotTransferFinished(version: Int, generation: Int) async throws {
        try await runEvent(.snapshotTransferFinished(version: version, generation: generation))
    }

    // MARK: - Test/diagnostic surface

    /// The current machine state — read-only, for tests and diagnostics.
    public var currentMachineState: BurlyPhoneSyncMachine.State { state }

    /// Awaits every debounce task spawned so far (catalog-edit and
    /// digest-publish alike), fired or superseded. Production never needs
    /// this — the whole point of coalescing is *not* waiting on it — but
    /// tests driving a manual scheduler need a deterministic point at which
    /// "everything that was going to fire, has" is true. See
    /// `QuietPeriodCoalescer.drain()`.
    public func drainPendingDebounces() async {
        await catalogDebouncer.drain()
        await digestCoalescer.drain()
    }

    /// Internal, not `private` — a test seam (`@testable import`) for
    /// pinning major 4 directly: how many command batches are currently
    /// queued behind the execution lock, waiting for the one in flight to
    /// finish. A test can poll this instead of guessing how long a
    /// concurrently-spawned push takes to reach the point where it would
    /// (incorrectly, pre-fix) start interleaving its own transport calls.
    var executionWaiterCountForTesting: Int { executionWaiters.count }

    // MARK: - Catalog-edit push: retry + surface (major 3)

    /// The debounced fire for a catalog edit. Unlike a session-ingest
    /// failure (item 3: silently drop, the watch's own retry re-drives it)
    /// or the install-flip/daily-push triggers (an edge or an interval to
    /// re-arm the check), a catalog edit has **no later signal** that
    /// naturally retries it — nothing else ever re-delivers "the catalog
    /// changed" for an edit that already happened. So a failure here is
    /// both **surfaced** (`lastCatalogPushFailure`, for a host app to
    /// observe) and **retried**: the exact commands `.catalogChanged`
    /// already produced are re-attempted, spaced by the configured
    /// debounce, up to `catalogPushRetryCount` extra times — never by
    /// re-delivering `.catalogChanged` to the machine again, which would
    /// bump `latestSnapshotVersion` a second time for one edit.
    private func deliverCatalogChanged() async {
        guard let commands = try? deliver(.catalogChanged) else {
            // `deliver` itself failing (the machine call or persisting its
            // result) is a harder failure than a transport/store hiccup
            // during execution — the machine never even recorded the edit,
            // so there are no commands to retry. Surfaced; a later genuine
            // edit is this trigger's only recovery path here, the same as
            // it always was.
            return
        }
        await executeCatalogCommands(commands, retriesRemaining: configuration.catalogPushRetryCount)
    }

    private func executeCatalogCommands(
        _ commands: [BurlyPhoneSyncMachine.Command],
        retriesRemaining: Int
    ) async {
        do {
            try await execute(commands, originalPayload: nil)
            lastCatalogPushFailure = nil
        } catch {
            lastCatalogPushFailure = error
            guard retriesRemaining > 0 else { return }
            let scheduler = self.scheduler
            let quietPeriod = configuration.catalogEditDebounce
            Task { [weak self] in
                try? await scheduler.sleep(for: quietPeriod)
                await self?.executeCatalogCommands(commands, retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    // MARK: - Command execution

    @discardableResult
    private func runEvent(_ event: BurlyPhoneSyncMachine.Event) async throws -> [BurlyPhoneSyncMachine.Command] {
        let commands = try deliver(event)
        try await execute(commands, originalPayload: nil)
        return commands
    }

    /// Runs one event through the machine and persists the resulting state
    /// before handing commands back — binding contract item 5, applied
    /// uniformly to every event rather than only the ack-bearing one: the
    /// state this method persists is always current the instant it
    /// changes, which is a strictly stronger guarantee than "persisted
    /// before the specific publish it produced" and needs no per-event-type
    /// bookkeeping to get right.
    private func deliver(_ event: BurlyPhoneSyncMachine.Event) throws -> [BurlyPhoneSyncMachine.Command] {
        let commands = machine.handle(event, &state, now: clock.now)
        try persistRuntimeState()
        return commands
    }

    private func persistRuntimeState() throws {
        try statePersisting.save(
            PhoneSyncRuntimeState(machineState: state, lastDailyPushAt: lastDailyPushAt)
        )
    }

    /// Internal, not `private` — a deliberate test seam (`@testable import`)
    /// so `PhoneSessionIngestTests` can drive binding-contract item 4 (a
    /// `.confirmSessionStored` verification that finds the row already
    /// gone) directly, by handing this a hand-built command against a store
    /// state the test controls, without needing a full `BurlyStore`-
    /// forwarding fake just to inject one stale lookup. Production only
    /// ever reaches this through `sessionReceived`/`runEvent`/
    /// `deliverCatalogChanged`.
    ///
    /// Major 4: this is the **only** entry point that runs a command batch,
    /// and it holds the execution lock for the batch's *entire* run,
    /// including whatever recursive confirm→publish chain
    /// `executeOne` triggers — never released until every command this
    /// call was given, and everything they caused, has finished.
    func execute(
        _ commands: [BurlyPhoneSyncMachine.Command],
        originalPayload: BurlySessionPayloadDTO?
    ) async throws {
        await acquireExecutionLock()
        defer { releaseExecutionLock() }
        try await executeUnlocked(commands, originalPayload: originalPayload)
    }

    private func executeUnlocked(
        _ commands: [BurlyPhoneSyncMachine.Command],
        originalPayload: BurlySessionPayloadDTO?
    ) async throws {
        for command in commands {
            try await executeOne(command, originalPayload: originalPayload)
        }
    }

    private func acquireExecutionLock() async {
        if isExecuting == false {
            isExecuting = true
            return
        }
        await withCheckedContinuation { continuation in
            executionWaiters.append(continuation)
        }
    }

    private func releaseExecutionLock() {
        guard executionWaiters.isEmpty == false else {
            isExecuting = false
            return
        }
        // Ownership transfers directly to the next waiter — `isExecuting`
        // stays `true` throughout, so there is no gap a third call could
        // slip into between "the last holder finished" and "the next one
        // starts."
        let next = executionWaiters.removeFirst()
        next.resume()
    }

    private func executeOne(
        _ command: BurlyPhoneSyncMachine.Command,
        originalPayload: BurlySessionPayloadDTO?
    ) async throws {
        switch command {
        case let .applySessionUpsert(_, _, payload):
            do {
                try applyIncomingSession(payload)
            } catch {
                // Item 3: a failed/rolled-back transaction sends nothing.
                // `SwiftDataStore.commit()`'s rollback-on-throw is what
                // makes "nothing" true at the store level too — the context
                // is rolled back before this catch ever runs, so no partial
                // write survives for anything else to observe.
                return
            }
            let confirmed = try deliver(.sessionStoreConfirmed(id: payload.session.id))
            try await executeUnlocked(confirmed, originalPayload: originalPayload)

        case let .confirmSessionStored(id, revision):
            let currentRevision = try store.session(id: id)?.revision
            if let currentRevision, currentRevision >= revision {
                let confirmed = try deliver(.sessionStoreConfirmed(id: id))
                try await executeUnlocked(confirmed, originalPayload: originalPayload)
            } else if let originalPayload {
                // Item 4: the advisory lookup lost a race (or the row was
                // deleted outright) — re-drive with the *current* observed
                // revision. No ack may escape from the stale decision.
                let rerouted = try deliver(
                    .sessionReceived(originalPayload, storedRevision: currentRevision)
                )
                try await executeUnlocked(rerouted, originalPayload: originalPayload)
            }
            // No `originalPayload` in hand cannot occur in practice — this
            // command is only ever produced by routing a `.sessionReceived`
            // event, and every recursive call above threads that same
            // payload through — but if it ever did, there is nothing to
            // re-route with, so this falls through to "do nothing" (no ack
            // can be synthesized without the payload to re-offer).

        case .publishDigest:
            // Major 5: the coalesced payload is a bare signal — `Void` —
            // not the command's own `(snapshotVersion, ackedSessionIDs)`.
            // Those are read from `self.state` inside `publishDigestNow`
            // at *fire* time, so a version bump or a fresher ack that lands
            // during the quiet period is never published stale.
            await digestCoalescer.coalesce(()) { [weak self] _ in
                await self?.publishDigestNow()
            }

        case let .transmitSnapshot(version, generation):
            let payload = try SnapshotPayloadBuilder.build(version: version, from: store)
            try await transport.transmitSnapshot(payload, generation: generation)

        case let .cancelSnapshotTransfer(version, generation):
            // Best-effort: a cancel that fails must never block the
            // `transmitSnapshot` that always follows it in the same batch
            // (§5 supersession — the new transfer must still start even if
            // the old one couldn't be told to stop).
            try? await transport.cancelSnapshotTransfer(version: version, generation: generation)
        }
    }

    /// Item 6's actual fire: derives the digest from full history, and from
    /// the machine's current `snapshotVersion`/acked-ids, **at this
    /// moment** — never from data captured when the burst started (major
    /// 5) — and publishes it. Errors are swallowed here on purpose — this
    /// runs from a detached debounce task with no caller left to propagate
    /// to by the time it fires; a failed derivation just means the next
    /// history-changed/confirmed event tries again.
    private func publishDigestNow() async {
        let snapshotVersion = state.latestSnapshotVersion
        let ackedSessionIDs = Set(state.ackAge.keys)
        guard let payload = try? SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: snapshotVersion,
            ackedSessionIDs: ackedSessionIDs
        ) else { return }
        await digestPublisher.publishDigest(payload)
    }

    /// §5 placeholder merge, plus the replicated session apply — one store
    /// transaction (m4-04 review round 1, major 1): see
    /// `BurlyStore.applyReplicatedSession(_:upsertingPlaceholderExercises:)`
    /// for why folding both into one `commit()` matters (a failure must not
    /// leave a committed placeholder behind with no session, no ack, and no
    /// way for a retry to know it was ever created for this delivery).
    private func applyIncomingSession(_ payload: BurlySessionPayloadDTO) throws {
        try store.applyReplicatedSession(
            payload.session,
            upsertingPlaceholderExercises: payload.needsNamingExercises
        )
    }
}
