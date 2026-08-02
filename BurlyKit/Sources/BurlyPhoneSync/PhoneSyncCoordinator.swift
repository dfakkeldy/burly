// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — PhoneSyncCoordinator
//
// The phone-side session ingest executor and push-trigger runtime
// `SyncMachineBinding.swift`'s BINDING CONTRACT describes.
//
// ## Why `@MainActor`, not a standalone `actor`
//
// `BurlyStore`'s own threading doc is explicit: "Create and use a store
// from one isolation domain (the app's `@MainActor` in practice)" — and the
// binding contract's item 1 asks for "the same executor as every other
// store mutation (§6 edits, deletes, imports)." Those two statements
// together rule out a standalone custom `actor` here: it would give the
// *sync* half of the app its own, independent isolation domain over a
// store object the *rest* of the app (§6's editor, §9's catalog browser)
// is expected to touch from `@MainActor` — two isolation domains racing
// over one non-`Sendable` `ModelContext`, which is precisely the hazard the
// store's doc calls out. Isolating this type to the global `@MainActor`
// instead means every store mutation in the app — a session ingest, a
// catalog-edit debounce firing, a §6 edit from a SwiftUI view — funnels
// through the one executor the whole platform already schedules UI and
// most app logic on, satisfying item 1 as an app-wide property rather than
// a property only provable within this module. (m4-03's own brief flags
// this exact choice — "`@MainActor` if all store work is main-isolated, or
// a dedicated `ModelActor`/executor" — as an open confinement decision; this
// task makes it explicitly for the phone-side runtime it owns.)
//
// ## Command execution, one contract item at a time
//
// - **Item 1 (single executor):** every `case` in `execute(one:...)` runs
//   on the main actor. `QuietPeriodCoalescer` is a *separate* actor (it
//   owns only sleep/generation bookkeeping, never the store), but every
//   closure it calls back into only ever does `await self.method()` on this
//   `@MainActor` type — the actual store work always hops back onto the
//   main actor before it happens, the same executor as everything else.
// - **Item 2 (conditional write):** `.applySessionUpsert` calls
//   `BurlyStore.applyReplicatedSession(_:)`, which rechecks the stored
//   revision *inside* its own transaction (see that method's doc) — this
//   runtime never recomputes or re-trusts the advisory `storedRevision` the
//   event carried.
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
// - **Item 6 (digest publications coalesce):** `.publishDigest`'s execution
//   goes through `digestCoalescer`, a `QuietPeriodCoalescer` — a burst of
//   confirmations/history-changed signals becomes one derivation (fetched
//   fresh, from the store, at fire time) and one `publishDigest` transport
//   call. The catalog-edit debounce (§5's 5 s edit window this item
//   explicitly mirrors) is the same mechanism, applied to
//   `.catalogChanged`.
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

        public init(
            catalogEditDebounce: Duration = .seconds(5),
            digestPublishDebounce: Duration = .seconds(5),
            dailyPushInterval: TimeInterval = 24 * 60 * 60
        ) {
            self.catalogEditDebounce = catalogEditDebounce
            self.digestPublishDebounce = digestPublishDebounce
            self.dailyPushInterval = dailyPushInterval
        }
    }

    private let store: any BurlyStore
    private let transport: any PhoneSyncTransporting
    private let digestPublisher: any PhoneDigestPublishing
    private let statePersisting: any PhoneSyncStatePersisting
    private let clock: any WallClock
    private let machine: BurlyPhoneSyncMachine
    private let configuration: Configuration

    private var state: BurlyPhoneSyncMachine.State
    private var lastDailyPushAt: Date?
    private var isWatchAppInstalled = false

    private let catalogDebouncer: QuietPeriodCoalescer<Void>
    private let digestCoalescer: QuietPeriodCoalescer<DigestRequest>

    private struct DigestRequest: Sendable, Equatable {
        var snapshotVersion: Int
        var ackedSessionIDs: Set<UUID>
    }

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
        self.machine = BurlyPhoneSyncMachine(configuration: machineConfiguration)
        self.configuration = configuration

        // Fail-safe, not fail-closed: a corrupt or unreadable state file
        // must not prevent the coordinator from existing at all. Every
        // field this loses is self-healing under the §5 protocol's own
        // idempotency (a lost ack just means the watch's retry re-earns it;
        // a lost snapshot version/generation restarts the monotonic line,
        // which only costs one redundant push, never a wedge).
        let loaded = try? statePersisting.load()
        self.state = loaded?.machineState ?? BurlyPhoneSyncMachine.State()
        self.lastDailyPushAt = loaded?.lastDailyPushAt

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
    /// false→true transition only — a redundant `true` (already installed)
    /// or a `false` never pushes anything on their own.
    public func watchAppInstalledDidChange(_ isInstalled: Bool) async throws {
        let wasInstalled = isWatchAppInstalled
        isWatchAppInstalled = isInstalled
        guard wasInstalled == false, isInstalled else { return }
        try await runEvent(.snapshotPushTriggered)
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
    public func dailyPushIfDue() async throws {
        let now = clock.now
        if let last = lastDailyPushAt, now.timeIntervalSince(last) < configuration.dailyPushInterval {
            return
        }
        lastDailyPushAt = now
        try persistRuntimeState()
        try await runEvent(.snapshotPushTriggered)
    }

    /// §5: "on any routine/catalog edit (debounced 5 s)". Call this once
    /// per edit; a burst within the quiet period collapses into exactly one
    /// `.catalogChanged` event — see `catalogDebouncer` and this file's
    /// binding-contract-item-6 note.
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

    // MARK: - Command execution

    private func deliverCatalogChanged() async {
        guard let commands = try? deliver(.catalogChanged) else { return }
        try? await execute(commands, originalPayload: nil)
    }

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
    /// ever reaches this through `sessionReceived`/`runEvent`.
    func execute(
        _ commands: [BurlyPhoneSyncMachine.Command],
        originalPayload: BurlySessionPayloadDTO?
    ) async throws {
        for command in commands {
            try await execute(one: command, originalPayload: originalPayload)
        }
    }

    private func execute(
        one command: BurlyPhoneSyncMachine.Command,
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
            try await execute(confirmed, originalPayload: originalPayload)

        case let .confirmSessionStored(id, revision):
            let currentRevision = try store.session(id: id)?.revision
            if let currentRevision, currentRevision >= revision {
                let confirmed = try deliver(.sessionStoreConfirmed(id: id))
                try await execute(confirmed, originalPayload: originalPayload)
            } else if let originalPayload {
                // Item 4: the advisory lookup lost a race (or the row was
                // deleted outright) — re-drive with the *current* observed
                // revision. No ack may escape from the stale decision.
                let rerouted = try deliver(
                    .sessionReceived(originalPayload, storedRevision: currentRevision)
                )
                try await execute(rerouted, originalPayload: originalPayload)
            }
            // No `originalPayload` in hand cannot occur in practice — this
            // command is only ever produced by routing a `.sessionReceived`
            // event, and every recursive `execute` call above threads that
            // same payload through — but if it ever did, there is nothing
            // to re-route with, so this falls through to "do nothing" (no
            // ack can be synthesized without the payload to re-offer).

        case let .publishDigest(snapshotVersion, ackedSessionIDs):
            let request = DigestRequest(snapshotVersion: snapshotVersion, ackedSessionIDs: ackedSessionIDs)
            await digestCoalescer.coalesce(request) { [weak self] request in
                await self?.publishDigestNow(request)
            }

        case let .transmitSnapshot(version, generation):
            let payload = try SnapshotPayloadBuilder.build(version: version, from: store)
            await transport.transmitSnapshot(payload, generation: generation)

        case let .cancelSnapshotTransfer(version, generation):
            await transport.cancelSnapshotTransfer(version: version, generation: generation)
        }
    }

    /// Item 6's actual fire: derives the digest from full history **at this
    /// moment** (never from data captured when the burst started) and
    /// publishes it. Errors are swallowed here on purpose — this runs from
    /// a detached debounce task with no caller left to propagate to by the
    /// time it fires; a failed derivation just means the next
    /// history-changed/confirmed event tries again.
    private func publishDigestNow(_ request: DigestRequest) async {
        guard let payload = try? SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: request.snapshotVersion,
            ackedSessionIDs: request.ackedSessionIDs
        ) else { return }
        await digestPublisher.publishDigest(payload)
    }

    /// §5 placeholder merge, plus the replicated session apply. Placeholder
    /// exercises upsert idempotently — created only when genuinely absent,
    /// never overwriting an exercise the phone (or an earlier delivery)
    /// already knows about, matching `applyCatalogSeed`'s "never overwrite"
    /// policy for the same reason: a `needsNaming` exercise may already
    /// have been named by the user between deliveries, and a redelivery
    /// must not un-name it.
    ///
    /// Runs the exercise upserts *before* `applyReplicatedSession`
    /// on purpose: `preflightSessionGraph` resolves every item's exercise
    /// reference and throws `.missingExercise` if it isn't stored yet, so a
    /// session naming a placeholder the phone has never seen would
    /// otherwise always fail.
    private func applyIncomingSession(_ payload: BurlySessionPayloadDTO) throws {
        for exercise in payload.needsNamingExercises where try store.exercise(id: exercise.id) == nil {
            try store.createExercise(exercise)
        }
        try store.applyReplicatedSession(payload.session)
    }
}
