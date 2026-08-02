// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncMachine — PhoneSyncMachine
//
// The phone half of the §5 sync protocol, as a pure state machine:
// `handle(event, &state, now:) -> [Command]`. Same seam rules as
// `WatchSyncMachine` (see that file and Package.swift): opaque payloads,
// UUID identity, Int revisions, nothing of Burly's domain.
//
// ## An ack is earned by the store, not by arrival (m4-02 review 1, #4)
//
// Session ingest is two-phase. `.sessionReceived` only *decides* — apply
// or drop by §5's revision rule — and emits the matching store command.
// The ack mutation and the digest publish happen exclusively in
// `.sessionStoreConfirmed`, which the runtime may send only after the
// store has durably committed (or atomically verified it already holds)
// an equal-or-newer row for that id. The first round of this machine
// acked on arrival, trusting the event's `storedRevision`; the review
// produced a concrete data-loss trace from that trust — a stale lookup
// racing a phone-side delete let an ack escape for a row the store no
// longer held, and the watch pruned its only durable copy on that ack.
// Structurally, an ack can now exist only downstream of a store
// confirmation; a runtime cannot leak one early without simply lying in
// `.sessionStoreConfirmed`, and the binding contract (BurlySync's
// `SyncMachineBinding.swift`) forbids exactly that. Confirmations are
// also *correlated* (m4-02 review 2, #3): each routing opens exactly one
// pending slot, a confirmation consumes it, and anything the machine
// cannot match to a slot — a duplicate, a crash-era replay, an id never
// routed — is ignored without touching retention, so replays cannot
// reset an ack's age and quietly defeat the 30-day bound.
//
// ## The stored revision rides the event — as advice, rechecked at the write
//
// §5's idempotency rule — incoming revision ≤ stored revision → drop
// silently; otherwise upsert by UUID — compares against the *store's*
// revision, and the store is the durable truth (phone edits bump it via
// `applyPhoneEdit`, deletes remove it — both outside this machine). The
// machine deliberately keeps no revision mirror of its own: a mirror must
// either chase every store mutation or drift, and a complete one is
// unbounded state — the exact thing the 30-day ack bound exists to avoid.
// So the runtime looks the stored revision up when a session payload
// arrives and hands it in on the event. That lookup can be stale by the
// time anything is written, which is why both store commands carry the
// incoming `revision` and require the runtime to recheck it inside the
// store transaction — the machine's decision routes the work; the write
// itself is conditional at the store, where the race cannot reach.
//
// ## Time is an input, and rollback can never extend retention
//
// The one time-based rule here — acked ids are retained ~30 days, bounded
// (§5) — reads the `now` handed to `handle`, never `Date()`. Expiry is
// *evaluated, not scheduled*: every `handle` call first ages the acks, so
// no timer needs to fire for the bound to hold.
//
// Age is **accumulated forward-only wall time**, not a stamp comparison
// (m4-02 review 1, #2). Each `handle` adds `max(0, now − lastObservedNow)`
// to every ack's age and expires ages ≥ retention. A wall clock that runs
// backwards (NTP, a manual date change) therefore adds nothing — it can
// never restart or stretch a retention window, however often it
// oscillates, which the stamp-plus-re-anchor design this replaces allowed
// indefinitely. The trade is explicit and chosen: a rollback followed by
// a correction is indistinguishable from genuinely elapsed time, so it
// ages acks *early* at worst. Early expiry is the safe direction in this
// protocol — an ack that expires before the watch saw it just means the
// watch retries and the redelivery re-earns the ack through the store —
// while late expiry is unbounded state with no repair path. No pure
// machine reading an injectable clock can bound true elapsed time against
// an adversarial clock (a wall clock frozen forever defers expiry
// forever, along with everything else); this is the honest contract, not
// a claimed absolute.
//
// Commands are obligations, not suggestions — `handle` is deliberately not
// `@discardableResult`, for the same reason as the watch machine's.
//
// Imports Foundation for `UUID`/`Date`/`TimeInterval` only.
import Foundation

/// The §5 phone-side protocol rules over an opaque session payload. The
/// phone's outbound payloads (snapshot, digest) are *built* by the runtime
/// from store truth, so the commands below carry only the identity facts —
/// version, acked ids — that this machine owns.
public struct PhoneSyncMachine<SessionPayload: Sendable & Equatable>: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// §5: "Phone keeps acked IDs 30 days (bounded), then drops them."
        /// An ack is retained while its accumulated age is strictly less
        /// than this; each store-confirmed re-delivery resets the age.
        public var ackRetention: TimeInterval

        public init(ackRetention: TimeInterval = 30 * 24 * 60 * 60) {
            precondition(ackRetention > 0, "Ack retention must be positive.")
            self.ackRetention = ackRetention
        }
    }

    /// One session ingest routed to the store and not yet confirmed: the
    /// revision the command carried, and how long the routing has waited.
    /// Ages exactly like an ack and is dropped at the same bound — a
    /// confirmation that takes longer than the retention window to arrive
    /// is dead anyway (the watch's retry re-drives the exchange), and
    /// aging keeps the pending map bounded even if a store transaction
    /// fails and its session is never redelivered.
    public struct PendingIngest: Sendable, Equatable {
        public var revision: Int
        public var age: TimeInterval

        public init(revision: Int, age: TimeInterval = 0) {
            precondition(age >= 0, "Pending ingest age must be non-negative.")
            self.revision = revision
            self.age = age
        }
    }

    /// Identity of one snapshot transfer: the catalog version it carries
    /// plus a monotonically increasing per-transfer generation. Version
    /// alone cannot tell a cancelled transfer's late callback apart from
    /// the live replacement carrying the *same* version (m4-02 review 2,
    /// #2) — push moments cancel-and-resend the current version, so two
    /// transfers of one version genuinely coexist.
    public struct SnapshotTransfer: Sendable, Equatable {
        public var version: Int
        public var generation: Int

        public init(version: Int, generation: Int) {
            self.version = version
            self.generation = generation
        }
    }

    /// Everything the phone side of the protocol remembers. A plain value;
    /// the runtime persists it (m4-05) — in particular `ackAge` and
    /// `lastObservedNow` must survive relaunch together (they are one
    /// fact: "how old each ack was, as of when") or every unpruned watch
    /// session redelivers as a fresh arrival, and `latestSnapshotVersion`
    /// and `lastTransferGeneration` must survive or the monotonic version
    /// and generation lines reset under the watch and the transport.
    public struct State: Sendable, Equatable {
        /// Accumulated forward-only age of each acked session id — the
        /// retention clock §5's 30-day bound runs against (see the file
        /// doc for why it is an age, not a stamp). The publishable ack
        /// set is this dictionary's keys.
        public fileprivate(set) var ackAge: [UUID: TimeInterval]

        /// The `now` of the last handled event — the base the next event's
        /// forward delta is measured from. A gap while the app was
        /// suspended is counted in full by the first event after resume.
        public fileprivate(set) var lastObservedNow: Date?

        /// Ingests routed to the store whose confirmations have not
        /// arrived. `.sessionStoreConfirmed` is honored only for ids in
        /// here, and removes them — at most once per routing (m4-02
        /// review 2, #3): a confirmation the machine cannot correlate to
        /// a command it issued (never routed, already consumed, or a
        /// replay from before a crash) is ignored without touching
        /// retention, so duplicates cannot keep an ack alive forever.
        public fileprivate(set) var pendingStoreConfirmations: [UUID: PendingIngest]

        /// The monotonic §5 snapshot version of the phone's current
        /// catalog+routine working set. Bumped only by `.catalogChanged`;
        /// push triggers re-send the current version.
        public fileprivate(set) var latestSnapshotVersion: Int

        /// The generation stamped on the most recent `transmitSnapshot`
        /// command — monotonic across every transfer this machine ever
        /// commanded, so no two transfers share an identity even at the
        /// same version.
        public fileprivate(set) var lastTransferGeneration: Int

        /// The transfer currently outstanding, if any — what §5's
        /// supersession rule ("a newer snapshot cancels any outstanding
        /// snapshot transfer") cancels against. Advisory, not
        /// load-bearing for liveness: a push moment re-sends the current
        /// version regardless, so a lost finished-callback can only cost
        /// one redundant cancel, never wedge the pipeline (m4-02 review 1,
        /// #3). Cleared only by a callback matching the full
        /// (version, generation) identity (review 2, #2).
        public fileprivate(set) var outstandingSnapshot: SnapshotTransfer?

        public init(
            ackAge: [UUID: TimeInterval] = [:],
            lastObservedNow: Date? = nil,
            pendingStoreConfirmations: [UUID: PendingIngest] = [:],
            latestSnapshotVersion: Int = 0,
            lastTransferGeneration: Int = 0,
            outstandingSnapshot: SnapshotTransfer? = nil
        ) {
            precondition(latestSnapshotVersion >= 0, "Snapshot version must be non-negative.")
            precondition(lastTransferGeneration >= 0, "Transfer generation must be non-negative.")
            precondition(ackAge.values.allSatisfy { $0 >= 0 }, "Ack ages must be non-negative.")
            self.ackAge = ackAge
            self.lastObservedNow = lastObservedNow
            self.pendingStoreConfirmations = pendingStoreConfirmations
            self.latestSnapshotVersion = latestSnapshotVersion
            self.lastTransferGeneration = lastTransferGeneration
            self.outstandingSnapshot = outstandingSnapshot
        }
    }

    public enum Event: Sendable, Equatable {
        /// A §5 `session` payload arrived from the watch. `revision` is the
        /// payload's own; `storedRevision` is the store's current revision
        /// for that id (`nil` when not stored), looked up by the runtime —
        /// see the file doc for why it rides the event and why it is
        /// advisory.
        case sessionReceived(id: UUID, revision: Int, storedRevision: Int?, payload: SessionPayload)

        /// The runtime's confirmation that the store **durably** holds a
        /// row for `id` at a revision ≥ the one the triggering command
        /// carried — either the conditional upsert committed, or the
        /// atomic verification found an equal-or-newer row. This is the
        /// only event that records an ack, and it is honored **at most
        /// once per routed command**: only while `id` is in
        /// `pendingStoreConfirmations` (m4-02 review 2, #3). Duplicates,
        /// crash-era replays, and confirmations for ids the machine never
        /// routed are ignored without touching retention. Sending one
        /// without the store guarantee remains a binding-contract
        /// violation (see `SyncMachineBinding.swift`) the machine cannot
        /// detect; the correlation here is defense in depth, not
        /// permission to replay.
        case sessionStoreConfirmed(id: UUID)

        /// Stored history changed locally — a §6 edit, a delete, an import.
        /// §5: the digest is refreshed whenever history changes.
        case historyChanged

        /// The catalog/routine working set changed. Debouncing the §5 5 s
        /// edit window is the runtime's scheduling concern; by the time
        /// this event arrives it means "one new working-set generation",
        /// and the version bumps exactly once for it.
        case catalogChanged

        /// A non-edit §5 push moment: app launch, `isWatchAppInstalled`
        /// flipping true, the daily push. Re-sends the current version —
        /// content did not change, so the version does not — cancelling
        /// any outstanding transfer first, so a lost finished-callback can
        /// never wedge these pushes (m4-02 review 1, #3).
        case snapshotPushTriggered

        /// The transport finished (or failed) the transfer identified by
        /// `(version, generation)` — both echoed from the
        /// `transmitSnapshot` command that started it (m4-02 review 2,
        /// #2: version alone aliases a cancelled transfer's late callback
        /// with its live same-version replacement). Completion is not
        /// "the watch applied it" — the watch's own version rule handles
        /// staleness — this only clears the outstanding slot so
        /// supersession has nothing left to cancel.
        case snapshotTransferFinished(version: Int, generation: Int)
    }

    public enum Command: Sendable, Equatable {
        /// Upsert this session into the store **conditionally**: one
        /// transaction that rechecks the stored revision at the write and
        /// commits the payload iff `revision` is still greater than what
        /// is stored (or nothing is). Either way the transaction ends
        /// with the store holding a row at ≥ `revision`; on durable
        /// commit the runtime feeds `.sessionStoreConfirmed(id:)` back.
        /// On failure it feeds nothing — no confirmation, no ack, and the
        /// watch's retry re-drives the whole exchange.
        case applySessionUpsert(id: UUID, revision: Int, payload: SessionPayload)

        /// The §5 "drop silently" path's store handshake: atomically
        /// verify the store still holds `id` at a revision ≥ `revision`.
        /// Held → feed `.sessionStoreConfirmed(id:)` (the re-ack the
        /// retrying watch is owed). Gone — the advisory `storedRevision`
        /// lost a race with a delete — feed the payload back through
        /// `.sessionReceived` with the current stored revision instead;
        /// no ack may escape from the stale decision (m4-02 review 1, #4).
        case confirmSessionStored(id: UUID, revision: Int)

        /// Publish a fresh §5 digest: the runtime derives the complete
        /// last-performance set from full history **at execution time**
        /// (the `SessionDigestReceipt` generator contract, owned with the
        /// generator in m4-05) and combines it with these machine-owned
        /// facts. Publications are latest-wins and individually
        /// disposable: only the final digest of a burst matters, and the
        /// runtime is obligated to coalesce bursts (a ghost-redelivery
        /// storm becomes one derivation and one publication, exactly as
        /// the §5 5 s debounce coalesces catalog edits — see the binding
        /// contract, m4-02 review 1, #5).
        case publishDigest(snapshotVersion: Int, ackedSessionIDs: Set<UUID>)

        /// Build the full catalog+routine payload at `version` from store
        /// truth and start its transfer. `generation` is this transfer's
        /// identity; the runtime must key its transfer bookkeeping by it
        /// and echo both values into `.snapshotTransferFinished`.
        case transmitSnapshot(version: Int, generation: Int)

        /// §5 supersession: cancel the outstanding transfer identified by
        /// `(version, generation)`. Always emitted before the
        /// `transmitSnapshot` that replaces it; cancelling a transfer the
        /// transport already finished or lost is a harmless no-op there.
        case cancelSnapshotTransfer(version: Int, generation: Int)
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Applies one event at wall-clock instant `now`. Pure and
    /// deterministic: same event, state, and `now` always yield the same
    /// new state and the same commands, in the same order.
    public func handle(_ event: Event, _ state: inout State, now: Date) -> [Command] {
        // §5's 30-day bound, evaluated before the event can read or
        // publish the ack set — see the file doc.
        ageAcks(&state, now: now)

        switch event {
        case let .sessionReceived(id, revision, storedRevision, payload):
            // §5 idempotency: incoming ≤ stored → drop silently. Either
            // branch is only a routing decision; the ack waits for the
            // store's confirmation, and the write/verify rechecks the
            // revision where the advisory lookup cannot be stale. The
            // routing is recorded so exactly one confirmation can be
            // honored for it — a re-route of the same id overwrites the
            // slot, which is correct: the serialized executor (binding
            // contract item 1) finishes one delivery before the next.
            state.pendingStoreConfirmations[id] = PendingIngest(revision: revision)
            let applies = storedRevision.map { revision > $0 } ?? true
            if applies {
                return [.applySessionUpsert(id: id, revision: revision, payload: payload)]
            }
            return [.confirmSessionStored(id: id, revision: revision)]

        case let .sessionStoreConfirmed(id):
            // Honored only against a routing this machine issued, at most
            // once (m4-02 review 2, #3): consuming the pending slot is
            // what makes a duplicate or crash-era replay inert — without
            // it, replayed confirmations could reset an ack's age forever
            // and the 30-day bound would be a fiction.
            guard state.pendingStoreConfirmations.removeValue(forKey: id) != nil else {
                return []
            }
            // The store durably holds the session (or an equal/newer row):
            // the ack is earned, its retention restarts, and the digest —
            // derived from history that now contains what it acks — goes
            // out.
            state.ackAge[id] = 0
            return [publishDigest(state)]

        case .historyChanged:
            return [publishDigest(state)]

        case .catalogChanged:
            state.latestSnapshotVersion += 1
            return replaceOutstandingTransfer(&state)

        case .snapshotPushTriggered:
            // Unconditionally cancel-and-resend the current version. The
            // machine cannot distinguish "genuinely in flight" from "the
            // finished callback was lost", and an earlier skip-if-in-flight
            // optimization wedged this path forever in the second case
            // (m4-02 review 1, #3): every push moment returned nothing,
            // and only a catalog edit could revive the pipeline. A
            // redundant cancel of a live transfer costs one requeue on a
            // launch/daily cadence; a silent wedge costs the watch every
            // future snapshot. Liveness wins.
            return replaceOutstandingTransfer(&state)

        case let .snapshotTransferFinished(version, generation):
            // Full-identity match only (m4-02 review 2, #2): a late
            // callback from a cancelled transfer — including one that
            // carried the *same version* as its live replacement — must
            // not clear the slot out from under the transfer that is
            // actually in flight.
            if state.outstandingSnapshot == SnapshotTransfer(version: version, generation: generation) {
                state.outstandingSnapshot = nil
            }
            return []
        }
    }

    /// §5 supersession plus the review-1 liveness rule, in one place:
    /// cancel whatever transfer is outstanding (harmless if it already
    /// finished) and transmit the current version under a fresh
    /// generation, which becomes the only identity whose callback can
    /// clear the slot.
    private func replaceOutstandingTransfer(_ state: inout State) -> [Command] {
        var commands: [Command] = []
        if let superseded = state.outstandingSnapshot {
            commands.append(.cancelSnapshotTransfer(
                version: superseded.version,
                generation: superseded.generation
            ))
        }
        state.lastTransferGeneration += 1
        let transfer = SnapshotTransfer(
            version: state.latestSnapshotVersion,
            generation: state.lastTransferGeneration
        )
        state.outstandingSnapshot = transfer
        commands.append(.transmitSnapshot(version: transfer.version, generation: transfer.generation))
        return commands
    }

    private func publishDigest(_ state: State) -> Command {
        .publishDigest(
            snapshotVersion: state.latestSnapshotVersion,
            ackedSessionIDs: Set(state.ackAge.keys)
        )
    }

    /// Adds the forward-only delta since the last handled event to every
    /// ack's — and every pending confirmation's — age, and drops the ones
    /// at or past retention. A backwards `now` contributes zero —
    /// rollback can shorten nothing and extend nothing; only observed
    /// forward wall time ages anything. See the file doc for why the
    /// correction after a rollback deliberately counts. Pending
    /// confirmations share the ack bound: a confirmation that has not
    /// arrived within the retention window never will (its executor is
    /// long gone), and sweeping it keeps the pending map bounded; a
    /// swept-then-arriving confirmation is safely ignored and the watch's
    /// retry re-drives the exchange.
    private func ageAcks(_ state: inout State, now: Date) {
        let delta: TimeInterval
        if let last = state.lastObservedNow {
            delta = Swift.max(0, now.timeIntervalSince(last))
        } else {
            delta = 0
        }
        state.lastObservedNow = now

        // The sweep runs even at delta 0: a rehydrated state may already
        // carry an over-age entry, and it must not survive into a publish
        // just because the clock has not moved since relaunch.
        for (id, age) in state.ackAge {
            let aged = age + delta
            if aged >= configuration.ackRetention {
                state.ackAge.removeValue(forKey: id)
            } else if delta > 0 {
                state.ackAge[id] = aged
            }
        }
        for (id, pending) in state.pendingStoreConfirmations {
            let aged = pending.age + delta
            if aged >= configuration.ackRetention {
                state.pendingStoreConfirmations.removeValue(forKey: id)
            } else if delta > 0 {
                state.pendingStoreConfirmations[id] = PendingIngest(revision: pending.revision, age: aged)
            }
        }
    }
}
