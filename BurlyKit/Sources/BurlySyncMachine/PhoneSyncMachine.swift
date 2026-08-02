// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncMachine — PhoneSyncMachine
//
// The phone half of the §5 sync protocol, as a pure state machine:
// `handle(event, &state, now:) -> [Command]`. Same seam rules as
// `WatchSyncMachine` (see that file and Package.swift): opaque payloads,
// UUID identity, Int revisions, nothing of Burly's domain.
//
// ## Time is an input
//
// The one time-based rule here — acked ids are retained ~30 days, bounded
// (§5) — reads the `now` handed to `handle`, never `Date()`. Expiry is
// *evaluated, not scheduled* (the same posture as BurlyCore's
// `GuardedWeightEditMachine`): every `handle` call first drops acks whose
// retention has lapsed, so no timer needs to fire for the bound to hold,
// and a suspended app cannot publish a digest carrying acks it should have
// forgotten.
//
// ## The stored revision rides the event
//
// §5's idempotency rule — incoming revision ≤ stored revision → drop
// silently; otherwise upsert by UUID — compares against the *store's*
// revision, and the store is the durable truth (phone edits bump it via
// `applyPhoneEdit`, deletes remove it — both outside this machine). The
// machine deliberately keeps no revision mirror of its own: a mirror must
// either chase every store mutation or drift, and a complete one is
// unbounded state — the exact thing the 30-day ack bound exists to avoid.
// So the runtime looks the stored revision up when a session payload
// arrives and hands it in on the event; the machine stays a pure decision
// over facts it was given.
//
// ## Acks and the ghost window
//
// Every received session is acked — including one the revision rule just
// dropped. A duplicate delivery means the watch has not seen the ack (that
// is why it retried), so the ack must be (re)published; each arrival also
// restamps the retention window. After the ~30 days, the id drops from the
// digest and a "ghost" redelivery of that session is still safe by the
// upsert rule: stored (revision ≥ incoming) → dropped and re-acked; deleted
// meanwhile → recreated whole, deterministically, no duplicate row either
// way. That recreation is §5's accepted trade — bounded ack state in
// exchange for a vanishingly rare resurrect — and it is pinned by test, not
// smoothed over.
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
        /// An ack is retained while strictly less than this old; each
        /// re-delivery of the session restamps it.
        public var ackRetention: TimeInterval

        public init(ackRetention: TimeInterval = 30 * 24 * 60 * 60) {
            precondition(ackRetention > 0, "Ack retention must be positive.")
            self.ackRetention = ackRetention
        }
    }

    /// Everything the phone side of the protocol remembers. A plain value;
    /// the runtime persists it (m4-05) — in particular `ackedAt` must
    /// survive relaunch or every unpruned watch session redelivers as a
    /// fresh arrival, and `latestSnapshotVersion` must survive or the
    /// monotonic version line resets under the watch.
    public struct State: Sendable, Equatable {
        /// When each session id was last received — the retention clock
        /// §5's 30-day bound runs against. The publishable ack set is this
        /// dictionary's keys.
        public fileprivate(set) var ackedAt: [UUID: Date]

        /// The monotonic §5 snapshot version of the phone's current
        /// catalog+routine working set. Bumped only by `.catalogChanged`;
        /// push triggers re-send the current version.
        public fileprivate(set) var latestSnapshotVersion: Int

        /// The version whose transfer is currently outstanding, if any —
        /// what §5's supersession rule ("a newer snapshot cancels any
        /// outstanding snapshot transfer") cancels against.
        public fileprivate(set) var outstandingSnapshotVersion: Int?

        public init(
            ackedAt: [UUID: Date] = [:],
            latestSnapshotVersion: Int = 0,
            outstandingSnapshotVersion: Int? = nil
        ) {
            precondition(latestSnapshotVersion >= 0, "Snapshot version must be non-negative.")
            self.ackedAt = ackedAt
            self.latestSnapshotVersion = latestSnapshotVersion
            self.outstandingSnapshotVersion = outstandingSnapshotVersion
        }
    }

    public enum Event: Sendable, Equatable {
        /// A §5 `session` payload arrived from the watch. `revision` is the
        /// payload's own; `storedRevision` is the store's current revision
        /// for that id (`nil` when not stored), looked up by the runtime —
        /// see the file doc for why it rides the event.
        case sessionReceived(id: UUID, revision: Int, storedRevision: Int?, payload: SessionPayload)

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
        /// content did not change, so the version does not.
        case snapshotPushTriggered

        /// The transport finished (or failed) the transfer of `version`.
        /// Completion is not "the watch applied it" — the watch's own
        /// version rule handles staleness — this only clears the
        /// outstanding slot so supersession has nothing left to cancel.
        case snapshotTransferFinished(version: Int)
    }

    public enum Command: Sendable, Equatable {
        /// Upsert this session into the store by UUID, taking the payload's
        /// revision at face value. Emitted only when the revision rule
        /// says the payload wins; a drop emits no command at all — §5's
        /// "drop silently" is the absence of this.
        case applySessionUpsert(id: UUID, payload: SessionPayload)

        /// Publish a fresh §5 digest: the runtime derives the complete
        /// last-performance set from full history (the
        /// `SessionDigestReceipt` generator contract, owned with the
        /// generator in m4-05) and combines it with these machine-owned
        /// facts.
        case publishDigest(snapshotVersion: Int, ackedSessionIDs: Set<UUID>)

        /// Build the full catalog+routine payload at `version` from store
        /// truth and start its transfer.
        case transmitSnapshot(version: Int)

        /// §5 supersession: cancel the outstanding transfer of `version`.
        /// Always emitted before the `transmitSnapshot` that replaces it;
        /// cancelling a transfer the transport already finished is a
        /// harmless no-op there.
        case cancelSnapshotTransfer(version: Int)
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
        expireAcks(&state, now: now)

        switch event {
        case let .sessionReceived(id, revision, storedRevision, payload):
            // §5 idempotency: incoming ≤ stored → drop silently.
            let applies = storedRevision.map { revision > $0 } ?? true
            // Ack unconditionally, restamping the retention window — a
            // duplicate arrived precisely because the watch lacks the ack.
            state.ackedAt[id] = now

            var commands: [Command] = []
            if applies {
                commands.append(.applySessionUpsert(id: id, payload: payload))
            }
            // History (maybe) changed and the ack set certainly did; both
            // halves ride the same digest (§5, latest-wins). Ordered after
            // the upsert: the digest must be derived from history that
            // already contains the session it acks.
            commands.append(publishDigest(state))
            return commands

        case .historyChanged:
            return [publishDigest(state)]

        case .catalogChanged:
            let superseded = state.outstandingSnapshotVersion
            state.latestSnapshotVersion += 1
            state.outstandingSnapshotVersion = state.latestSnapshotVersion
            var commands: [Command] = []
            if let superseded {
                // §5: a newer snapshot cancels any outstanding transfer.
                commands.append(.cancelSnapshotTransfer(version: superseded))
            }
            commands.append(.transmitSnapshot(version: state.latestSnapshotVersion))
            return commands

        case .snapshotPushTriggered:
            if state.outstandingSnapshotVersion == state.latestSnapshotVersion,
               state.outstandingSnapshotVersion != nil {
                // The current version is already on its way; a second
                // transfer of identical content helps nobody.
                return []
            }
            var commands: [Command] = []
            if let stale = state.outstandingSnapshotVersion {
                // Only reachable when an older version is still in flight
                // (its `.snapshotTransferFinished` never arrived — e.g. a
                // relaunch lost the callback). Supersede it exactly as
                // `.catalogChanged` would have.
                commands.append(.cancelSnapshotTransfer(version: stale))
            }
            state.outstandingSnapshotVersion = state.latestSnapshotVersion
            commands.append(.transmitSnapshot(version: state.latestSnapshotVersion))
            return commands

        case let .snapshotTransferFinished(version):
            // A late callback for a superseded (cancelled) transfer must
            // not clear the slot out from under the newer one.
            if state.outstandingSnapshotVersion == version {
                state.outstandingSnapshotVersion = nil
            }
            return []
        }
    }

    private func publishDigest(_ state: State) -> Command {
        .publishDigest(
            snapshotVersion: state.latestSnapshotVersion,
            ackedSessionIDs: Set(state.ackedAt.keys)
        )
    }

    /// Drops every ack whose retention lapsed. A wall clock can run
    /// backwards (NTP, a manual date change), leaving an ack stamped in
    /// the future — re-anchored to `now` on sight, same as
    /// `GuardedWeightEditMachine`'s idle anchor, so a backwards jump cannot
    /// extend retention past the bound measured from here.
    private func expireAcks(_ state: inout State, now: Date) {
        for (id, stampedAt) in state.ackedAt {
            if stampedAt > now {
                state.ackedAt[id] = now
            } else if now.timeIntervalSince(stampedAt) >= configuration.ackRetention {
                state.ackedAt.removeValue(forKey: id)
            }
        }
    }
}
