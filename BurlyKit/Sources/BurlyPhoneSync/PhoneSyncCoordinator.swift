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
//   `PhoneSyncStatePersisting`'s journal record contains the complete state,
//   including both monotonic snapshot identities — see that protocol's doc.
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
    /// m4-04 review round 2, finding 5: incremented once per catalog-edit
    /// batch (`deliverCatalogChanged` invocation — the debounced fire for
    /// one coalesced edit). A retry scheduled by an OLDER batch captures
    /// its own epoch and re-checks it immediately before doing anything
    /// that could touch persistence or the transport, against whatever
    /// this counter currently holds. A mismatch means a NEWER catalog edit
    /// has already run its own full delivery in the meantime — that
    /// edit's commands (built from the machine's state as of ITS delivery,
    /// which by construction already reflects and supersedes whatever the
    /// older batch saw) are the only ones that should still be trying to
    /// land; the older batch's retry chain has nothing useful left to
    /// contribute and must not run (it would otherwise resurrect a
    /// transfer the newer batch's own cancel already retired).
    private var catalogBatchEpoch = 0
    /// `true` when `init` skipped invalid journal data (or migrated a legacy
    /// recovery) to reconstruct state — a surfaced event, not a silent reset.
    public private(set) var recoveredFromCorruptState = false
    /// m4-04 review round 2, finding 1 + round 3, §1: `true` when `init`
    /// found a present journal with zero checksum-valid records
    /// (`PhoneSyncStateUnrecoverableError`). The
    /// coordinator still constructs (with a fresh, zeroed `State` — there
    /// is nothing else to build one from), but that zero is NOT a resumed
    /// identity, and while this flag is `true` the coordinator is
    /// **quiescent**: every public trigger and ingest entry point is a
    /// silent no-op — no machine event runs, no state is persisted, and
    /// **nothing is ever handed to the transport or the digest publisher**
    /// (round 3, §1: detection alone was not enough — a zeroed state that
    /// still pushes retransmits `(version, generation)` identities this
    /// phone already used, regressing the watch below its true version and
    /// aliasing generations a live transfer may still hold). Nothing is
    /// lost by the quiescence: the watch retains its own durable copy of
    /// every session until an ack it will not receive, and re-delivers
    /// after the relationship is rebuilt.
    ///
    /// The only exit is the caller-invoked, explicit
    /// `resetSyncStateForRePair()` — re-pairing/rebuilding the sync
    /// relationship is a decision only a host app (and ultimately the
    /// user) can make; this flag makes sure it is never made silently, and
    /// the gates make sure no stale identity leaves the device while it is
    /// pending.
    public private(set) var syncStateUnrecoverable = false

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
        // identity — see `PhoneSyncStatePersisting`'s doc.
        do {
            if let result = try statePersisting.load() {
                self.state = result.runtimeState.machineState
                self.lastDailyPushAt = result.runtimeState.lastDailyPushAt
                self.recoveredFromCorruptState = result.recoveredFromCorruption
            } else {
                self.state = BurlyPhoneSyncMachine.State()
                self.lastDailyPushAt = nil
            }
        } catch is PhoneSyncStateUnrecoverableError {
            // The journal exists but no record provides a trustworthy identity —
            // construct a fresh state (there is nothing else to build one
            // from), flag it distinctly from an ordinary single-file
            // corruption recovery, and QUIESCE: every push/ingest entry
            // point below gates on `syncStateUnrecoverable`, so this
            // zeroed state can never be transmitted, persisted, or
            // laundered into a clean-looking save. "Start fresh" here
            // genuinely risks reusing/aliasing an identity a live transfer
            // or the watch's own records still remember — the flag alone
            // (round 2's fix) surfaced that risk without preventing it.
            self.state = BurlyPhoneSyncMachine.State()
            self.lastDailyPushAt = nil
            self.recoveredFromCorruptState = true
            self.syncStateUnrecoverable = true
        } catch {
            // Any other thrown error (e.g. a conformer with its own
            // failure modes) is a harder failure than a single documented
            // corruption case but not the specific zero-valid-record
            // condition above — treated the same fail-safe way round
            // 1 established: fresh state, surfaced as a corruption
            // recovery.
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
        // Round 3, §1: quiescent while unrecoverable — a delivery accepted
        // here would end in an ack + digest publish carrying a zeroed
        // identity. Dropping it silently is safe: the watch keeps its own
        // durable copy until the ack that will not come, and re-delivers
        // once the relationship is rebuilt.
        guard syncStateUnrecoverable == false else { return }
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
        guard syncStateUnrecoverable == false else { return } // Round 3, §1.
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
        // Round 3, §1: quiescent while unrecoverable — not even the edge
        // bookkeeping runs, so a post-reset install signal (the host app
        // re-drives current install state after a re-pair) is a clean
        // false→true edge again.
        guard syncStateUnrecoverable == false else { return }
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
        guard syncStateUnrecoverable == false else { return } // Round 3, §1.
        let now = clock.now
        if let last = lastDailyPushAt, now.timeIntervalSince(last) < configuration.dailyPushInterval {
            return
        }
        try await runEvent(.snapshotPushTriggered)
        // Round 4: the "day consumed" mark advances through the same
        // persist-then-commit point as everything else — never in memory
        // first. (Major 3 kept a FAILED push from consuming the day; this
        // keeps an unpersisted success mark from diverging memory and
        // disk: if this save fails, the next check retries, exactly as a
        // relaunch would have.)
        try persistThenCommit(PhoneSyncRuntimeState(machineState: state, lastDailyPushAt: now))
    }

    /// §5: "on any routine/catalog edit (debounced 5 s)". Call this once
    /// per edit; a burst within the quiet period collapses into exactly one
    /// `.catalogChanged` event — see `catalogDebouncer` and
    /// `deliverCatalogChanged`'s doc for what happens if the push that
    /// results from it fails.
    public func catalogDidChange() async {
        // Round 3, §1: quiescent while unrecoverable — not even a debounce
        // countdown is scheduled (nothing may fire later either).
        guard syncStateUnrecoverable == false else { return }
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
        guard syncStateUnrecoverable == false else { return } // Round 3, §1.
        try await runEvent(.historyChanged)
    }

    /// The transport's completion (or failure) callback for a snapshot
    /// transfer, echoing the `(version, generation)` identity
    /// `.transmitSnapshot` started it with.
    public func snapshotTransferFinished(version: Int, generation: Int) async throws {
        // Round 3, §1: quiescent while unrecoverable. Handling a late
        // transport callback would run `deliver(_:)`, whose
        // `persistRuntimeState()` would launder the zeroed state into a
        // clean-looking save — making the NEXT relaunch load `(0, 0)` as
        // if it were a resumed identity, with no unrecoverable flag at all.
        guard syncStateUnrecoverable == false else { return }
        try await runEvent(.snapshotTransferFinished(version: version, generation: generation))
    }

    // MARK: - Explicit reset (round 3, §1 — the only exit from quiescence)

    /// The caller-invoked exit from the `syncStateUnrecoverable` quiescent
    /// mode: durably persists a **fresh, zeroed identity domain** and only
    /// then lifts the gates.
    ///
    /// ## Contract
    ///
    /// - **Call this only as part of deliberately rebuilding the sync
    ///   relationship** (a re-pair: the watch app reinstalled/reset, so the
    ///   watch's own §5 state — its adopted snapshot version, its pruning
    ///   bookkeeping — is fresh too). The §5 wire protocol carries no
    ///   explicit domain/epoch marker, so the watch "recognizes" the reset
    ///   only through the re-pair itself: a genuinely fresh watch accepts
    ///   the restarted version line from zero exactly as it would a first
    ///   pairing.
    /// - **Misuse cannot corrupt, only stall.** If a caller invokes this
    ///   against a watch that was NOT reset, the watch's own version rule
    ///   refuses the regressed snapshot versions (stalled adoption until
    ///   the restarted line catches up), and `snapshotTransferFinished`'s
    ///   full-identity match means a pre-corruption transfer's late
    ///   callback can at worst prematurely clear the advisory outstanding
    ///   slot — a cost §5's cancel-and-resend liveness already absorbs.
    ///   No identity ever regresses on the *watch's* side and no data is
    ///   overwritten; still, the intended flow is reset-both-sides.
    /// - **No-op unless unrecoverable.** On a healthy coordinator this
    ///   returns immediately — it can never be used to regress a live
    ///   identity line.
    /// - **Durability before liveness, atomically.** The fresh state is
    ///   persisted *first*, through
    ///   `PhoneSyncStatePersisting.replaceWithFreshIdentityDomain(_:)` —
    ///   an all-or-nothing domain replacement, NOT an ordinary `save`
    ///   (round 4, §2): `save`'s incremental append-the-log-then-write-
    ///   the-primary shape is safe for ordinary upward identities but,
    ///   for a reset's zero, a partial write would orphan a trustworthy-
    ///   looking `(0, 0)` log record that the NEXT launch recovers
    ///   operationally — laundering a reset that never committed across
    ///   the process boundary. On any persistence failure here, the error
    ///   propagates, this coordinator stays fully quiescent, and the
    ///   durable state is indistinguishable from "reset never happened" —
    ///   so the relaunch is still unrecoverable and still quiescent.
    /// - Does not invent or recover identities: the pre-corruption
    ///   `(version, generation)` line is gone, and this deliberately does
    ///   not guess at it (round 3, §1 — no invented identities). It starts
    ///   a new line the re-paired watch treats as fresh.
    public func resetSyncStateForRePair() throws {
        guard syncStateUnrecoverable else { return }
        let fresh = PhoneSyncRuntimeState(machineState: BurlyPhoneSyncMachine.State(), lastDailyPushAt: nil)
        try statePersisting.replaceWithFreshIdentityDomain(fresh)
        state = fresh.machineState
        lastDailyPushAt = nil
        pendingInstallPushRetry = false
        lastCatalogPushFailure = nil
        syncStateUnrecoverable = false
        recoveredFromCorruptState = false
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

    /// Internal test seam (round 3, §6): the most recently scheduled
    /// catalog-push retry `Task`. A retry is deliberately untracked in
    /// production (fire-and-forget; nothing awaits it), which left the
    /// stale-retry pin with no completion signal — a fixed wall-clock
    /// sleep cannot prove the retry did NOT transmit, because the executor
    /// may simply not have scheduled it inside the window. Awaiting this
    /// handle's `value` is the deterministic signal: when it resumes, the
    /// retry has definitely run to completion — reached its epoch check
    /// and either backed off (post-fix) or replayed its stale commands
    /// (pre-fix) — so a negative assertion after it cannot be a false
    /// green. Holding the last handle changes no production behavior.
    private(set) var mostRecentCatalogRetryTaskForTesting: Task<Void, Never>?

    // MARK: - Catalog-edit push: retry + surface (major 3)

    /// The debounced fire for a catalog edit. Unlike a session-ingest
    /// failure (item 3: silently drop, the watch's own retry re-drives it)
    /// or the install-flip/daily-push triggers (an edge or an interval to
    /// re-arm the check), a catalog edit has **no later signal** that
    /// naturally retries it — nothing else ever re-delivers "the catalog
    /// changed" for an edit that already happened. So a failure here is
    /// both **surfaced** (`lastCatalogPushFailure`, for a host app to
    /// observe) and **retried**, spaced by the configured debounce, up to
    /// `catalogPushRetryCount` extra times (round 2, finding 4: a persist
    /// failure gets the same treatment as a transport failure).
    ///
    /// How a retry retries depends on which half failed — round 4's
    /// commit-after-persist makes the two cases cleanly distinct (see
    /// `runCatalogBatch`'s doc): a PERSIST failure means nothing was
    /// committed, so the retry re-delivers `.catalogChanged` — still
    /// exactly one version bump for the edit, because the failed
    /// attempt's bump never existed; a TRANSPORT failure means the state
    /// IS committed, so the retry replays the committed commands,
    /// freshness-guarded against supersession.
    private func deliverCatalogChanged() async {
        // Round 3, §1: defense in depth — `catalogDidChange()` is already
        // gated (and the flag is only ever set in `init`, before any
        // debounce can exist), but a debounced fire must never transmit
        // from an unrecoverable state regardless of how it was scheduled.
        guard syncStateUnrecoverable == false else { return }
        catalogBatchEpoch += 1
        let epoch = catalogBatchEpoch
        await runCatalogBatch(epoch: epoch, retriesRemaining: configuration.catalogPushRetryCount)
    }

    /// Delivers `.catalogChanged` (state advances only through
    /// `persistThenCommit` — round 4's root cause) and executes the
    /// resulting commands, surfacing and retrying either half's failure
    /// (round 2, finding 4).
    ///
    /// Round 4: a **persist** failure retry RE-DELIVERS the event rather
    /// than replaying a captured candidate. Under commit-after-persist, a
    /// failed persist means the event never happened — nothing was
    /// committed in memory or on disk — so re-delivering derives a fresh
    /// candidate from whatever the CURRENT committed truth is by retry
    /// time (an interleaved launch push, an ingest's ack — all included),
    /// and still bumps the version exactly once per edit, because the
    /// failed attempt's bump never existed anywhere. Replaying a stale
    /// candidate instead would clobber every commit that landed in
    /// between and re-mint identities the interleaved events already
    /// used. (A **transport** failure retry, below, is the opposite case:
    /// its state IS committed, so it replays the committed commands.)
    ///
    /// Every entry — first attempt and every retry — re-checks `epoch`
    /// (round 2, finding 5): once a newer edit's batch has run, this one
    /// backs off; the newer batch's snapshot is built from store truth and
    /// already carries this edit's content.
    private func runCatalogBatch(epoch: Int, retriesRemaining: Int) async {
        guard epoch == catalogBatchEpoch else { return }
        let commands: [BurlyPhoneSyncMachine.Command]
        do {
            commands = try deliver(.catalogChanged)
        } catch {
            lastCatalogPushFailure = error
            guard retriesRemaining > 0 else { return }
            let scheduler = self.scheduler
            let quietPeriod = configuration.catalogEditDebounce
            mostRecentCatalogRetryTaskForTesting = Task { [weak self] in
                try? await scheduler.sleep(for: quietPeriod)
                await self?.runCatalogBatch(epoch: epoch, retriesRemaining: retriesRemaining - 1)
            }
            return
        }
        await executeCatalogCommands(commands, epoch: epoch, retriesRemaining: retriesRemaining)
    }

    private func executeCatalogCommands(
        _ commands: [BurlyPhoneSyncMachine.Command],
        epoch: Int,
        retriesRemaining: Int
    ) async {
        guard epoch == catalogBatchEpoch else { return }
        // Round 4 audit: the epoch only tracks catalog-edit supersession —
        // a NON-catalog push (launch, install flip, daily) can also mint a
        // newer transfer between this batch's transport failure and its
        // retry, and replaying then would resurrect a transfer that newer
        // push's own cancel already retired (the same resurrection round
        // 2's finding 5 closed for catalog-after-catalog, via a trigger
        // the epoch cannot see). Generations are strictly monotonic and
        // minted only through `deliver`'s commit, so "this batch's
        // transmit still names the newest generation" is an exact
        // freshness check: on a mismatch, something newer is already the
        // live transfer and this batch has nothing left to contribute.
        guard let batchGeneration = transmitGeneration(in: commands),
              batchGeneration == state.lastTransferGeneration else { return }
        do {
            try await execute(commands, originalPayload: nil)
            lastCatalogPushFailure = nil
        } catch {
            lastCatalogPushFailure = error
            guard retriesRemaining > 0 else { return }
            let scheduler = self.scheduler
            let quietPeriod = configuration.catalogEditDebounce
            mostRecentCatalogRetryTaskForTesting = Task { [weak self] in
                try? await scheduler.sleep(for: quietPeriod)
                await self?.executeCatalogCommands(commands, epoch: epoch, retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    /// The generation of the batch's `transmitSnapshot`, if any — the
    /// identity `executeCatalogCommands`' freshness guard compares against
    /// the committed `lastTransferGeneration`. Every `.catalogChanged`
    /// batch carries exactly one.
    private func transmitGeneration(in commands: [BurlyPhoneSyncMachine.Command]) -> Int? {
        for command in commands {
            if case let .transmitSnapshot(_, generation) = command {
                return generation
            }
        }
        return nil
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
    /// uniformly to every event rather than only the ack-bearing one.
    ///
    /// Round 4 (§2/§3 root cause): the machine runs on a **local copy** of
    /// the state, and `self.state` advances only after `save` has both
    /// validated and durably written that copy — persistence is the source
    /// of truth, and in-memory state never advances past validly-persisted
    /// state. Before this, `machine.handle` mutated `self.state` in place
    /// and only THEN persisted: a rejected save (the identity ceiling) or a
    /// failed save (I/O) left the runtime holding — and separately-scheduled
    /// work like a pending digest fire *observing* — a value that was never
    /// valid or never durable. That is the round-4 review's exact
    /// ceiling+1-to-the-digest-publisher trace. A failed persist now means
    /// the event never happened, in memory exactly as on disk; the thrown
    /// error tells the caller precisely that, and re-attempting the event
    /// later re-derives everything from committed truth.
    private func deliver(_ event: BurlyPhoneSyncMachine.Event) throws -> [BurlyPhoneSyncMachine.Command] {
        var candidate = state
        let commands = machine.handle(event, &candidate, now: clock.now)
        try persistThenCommit(PhoneSyncRuntimeState(machineState: candidate, lastDailyPushAt: lastDailyPushAt))
        return commands
    }

    /// Round 4: THE single point where the coordinator's persisted runtime
    /// state (`state` + `lastDailyPushAt`) is allowed to advance. `save`
    /// validates the identity bounds and durably writes first; only then
    /// is the candidate adopted in memory. Every mutation of those two
    /// properties outside `init` and the (equally persist-first)
    /// `resetSyncStateForRePair` goes through here, so no reader — a
    /// pending digest fire, `currentMachineState`, a later relaunch — can
    /// ever observe a value persistence did not confirm.
    private func persistThenCommit(_ candidate: PhoneSyncRuntimeState) throws {
        try statePersisting.save(candidate)
        state = candidate.machineState
        lastDailyPushAt = candidate.lastDailyPushAt
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
        // Round 3, §1: the last line of defense — every transport call in
        // this type flows through here (and every digest publish through
        // `publishDigestNow`, gated the same way), so even a path that
        // slipped past the per-trigger gates cannot transmit from an
        // unrecoverable state.
        guard syncStateUnrecoverable == false else { return }
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
        // Round 3, §1: the digest publisher is a transmission to the watch
        // too (it carries `snapshotVersion`) — gated like the transport.
        guard syncStateUnrecoverable == false else { return }
        let snapshotVersion = state.latestSnapshotVersion
        // Round 4, §3 belt-and-suspenders: with commit-after-persist
        // (`deliver`/`persistThenCommit`), `state` can never hold an
        // out-of-domain version — but this is the LAST boundary before an
        // identity reaches the watch through the digest channel, so it
        // refuses independently, exactly as `execute` and the transport
        // path are covered by `save`'s validation.
        guard snapshotVersion >= 0, snapshotVersion <= maximumPhoneSyncIdentity else { return }
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
