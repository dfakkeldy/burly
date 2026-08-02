// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncMachine — WatchSyncMachine
//
// The watch half of the §5 sync protocol, as a pure state machine:
// `handle(event, &state) -> [Command]`, the same idiom as BurlyCore's
// session engine machines. No transport, no persistence, no clock — the
// watch side has no time-based rule at all, so there is nothing to inject.
//
// ## Why this module knows no Burly type
//
// The machine is generic over three opaque payload type parameters and
// otherwise speaks only `UUID` identity and `Int` versions. That is the
// whole point of this target existing (see Package.swift): the §5 rules —
// outbox-until-ack, whole-replace snapshots, latest-wins digests — are not
// about lifting, and Free Lunch will run the identical machine over its own
// payloads. Facts the machine needs (a session's id, a snapshot's version,
// a digest's acked ids) arrive *on the event*, extracted by the adapter in
// BurlySync; the payload itself passes through untouched, never inspected.
//
// ## The one rule that carries the outbox (§5)
//
// A completed session leaves the outbox **only** when its id appears in a
// received digest's acked ids. Transfer-API callbacks are never delivery
// proof: WatchConnectivity's "did finish" means the payload left this
// device, not that the phone durably stored it, and treating it as more
// than that is exactly how a crashed phone loses a workout. So
// `.sessionTransferCallback` — success or failure alike — moves nothing.
// Retry is not scheduled either; §5 retries on every app/WC activation,
// which arrives here as `.activated`.
//
// ## State is the persistable value
//
// §5's outbox is *persisted*. This machine owns the semantics; durability
// is m4-04's, which persists `State` (at minimum `outbox`, and
// `lastAppliedSnapshotVersion` atomically with the snapshot's store apply,
// or a crash between the two replays/holds a snapshot — replay is safe
// either way because whole-replace application is idempotent).
//
// Commands are obligations, not suggestions: `handle` is deliberately not
// `@discardableResult`, because a dropped `.applyDigest` is a lost prune
// and a dropped `.transmitSession` is a stalled outbox until the next
// activation.
//
// Imports Foundation for `UUID` only.
import Foundation

/// The §5 watch-side protocol rules over opaque payloads. See the file doc
/// for the seam rationale; see `BurlySync`'s machine binding for the
/// concrete payload types and the command → transport/store mapping.
public enum WatchSyncMachine<
    SessionPayload: Sendable & Equatable,
    SnapshotPayload: Sendable & Equatable,
    DigestPayload: Sendable & Equatable
> {
    /// One completed session awaiting the phone's ack: its stable identity,
    /// and the payload to (re)transmit verbatim until the ack arrives.
    public struct OutboxEntry: Sendable, Equatable {
        public let id: UUID
        public var payload: SessionPayload

        public init(id: UUID, payload: SessionPayload) {
            self.id = id
            self.payload = payload
        }
    }

    /// Everything the watch side of the protocol remembers. A plain value:
    /// the runtime rehydrates one at launch and persists it after handling
    /// each event (m4-04).
    public struct State: Sendable, Equatable {
        /// Completion order, oldest first; retransmission preserves it.
        public fileprivate(set) var outbox: [OutboxEntry]

        /// The version of the last snapshot actually applied, or `nil` on a
        /// fresh install (which is why the first snapshot of any version —
        /// including 0 — applies). Snapshots at or below this are dropped:
        /// `transferFile` can redeliver after a crash and a superseded
        /// transfer can land late, and a whole-working-set replace must
        /// never run backwards.
        public fileprivate(set) var lastAppliedSnapshotVersion: Int?

        public init(outbox: [OutboxEntry] = [], lastAppliedSnapshotVersion: Int? = nil) {
            self.outbox = outbox
            self.lastAppliedSnapshotVersion = lastAppliedSnapshotVersion
        }
    }

    /// Everything that can reach the watch machine. Identity facts ride on
    /// the event next to the opaque payload they describe — the adapter
    /// extracts them once, at the boundary, so the machine never looks
    /// inside a payload.
    public enum Event: Sendable, Equatable {
        /// A session finished on this device (§2 Finish) and must reach the
        /// phone. Enters the outbox and is transmitted immediately.
        case sessionCompleted(id: UUID, payload: SessionPayload)

        /// App activation or WC activation callback — §5's retry moments.
        /// `alreadyQueuedSessionIDs` is the transport's own outstanding
        /// queue (WCSession exposes it), so an entry whose transfer is
        /// still pending is not enqueued a second time; pass `[]` when the
        /// transport cannot say. Duplicates are safe either way — the
        /// phone's revision rule drops them — this only avoids queue bloat.
        case activated(alreadyQueuedSessionIDs: Set<UUID>)

        /// The transfer API reported an attempt finished. **Never delivery
        /// proof** (§5) — handled as a deliberate no-op in both outcomes,
        /// and the case exists so that the no-op is a pinned, tested rule
        /// rather than an omission.
        case sessionTransferCallback(id: UUID, reportedSuccess: Bool)

        /// A §5 `snapshot` arrived. `version` is the payload's monotonic
        /// catalog version, extracted by the adapter.
        case snapshotReceived(version: Int, payload: SnapshotPayload)

        /// A §5 `digest` arrived. `ackedSessionIDs` are the sessions the
        /// phone asserts it has durably received, extracted by the adapter.
        case digestReceived(ackedSessionIDs: Set<UUID>, payload: DigestPayload)
    }

    /// What the runtime must do in response — hand payloads to the
    /// transport or to the store. The machine never sees the result;
    /// outcomes it cares about come back as later events.
    public enum Command: Sendable, Equatable {
        /// Enqueue this session on the watch→phone channel, verbatim.
        case transmitSession(id: UUID, payload: SessionPayload)

        /// Whole-working-set replace of catalog and routines (§5). The
        /// recorded `lastAppliedSnapshotVersion` must be persisted
        /// atomically with this apply — see the file doc.
        case applySnapshot(version: Int, payload: SnapshotPayload)

        /// Latest-wins digest apply (§5): upsert the entries and prune the
        /// acked sessions as one store transaction. Unconditional — the
        /// machine cannot and does not audit digest contents; an empty
        /// entry list next to real acks is a legitimate payload (the phone
        /// may have deleted history), and refusing it would strand those
        /// sessions on the watch forever once the acks age out (§5, m1-06
        /// review round F).
        case applyDigest(payload: DigestPayload)
    }

    /// Applies one event. Pure and deterministic: same event against the
    /// same state always yields the same new state and the same commands,
    /// in the same order.
    public static func handle(_ event: Event, _ state: inout State) -> [Command] {
        switch event {
        case let .sessionCompleted(id, payload):
            // Upsert by id: a replayed completion (crash after Finish,
            // before the persisted state caught up) must not enqueue the
            // session twice. The payload is refreshed because same id
            // means same session, and the newer serialization wins.
            if let index = state.outbox.firstIndex(where: { $0.id == id }) {
                state.outbox[index].payload = payload
            } else {
                state.outbox.append(OutboxEntry(id: id, payload: payload))
            }
            // §5: "transfer attempted immediately".
            return [.transmitSession(id: id, payload: payload)]

        case let .activated(alreadyQueuedSessionIDs):
            // §5: retry everything still unacked, in completion order.
            return state.outbox
                .filter { !alreadyQueuedSessionIDs.contains($0.id) }
                .map { .transmitSession(id: $0.id, payload: $0.payload) }

        case .sessionTransferCallback:
            // Never delivery proof (§5) — see the file doc. A failure is
            // not retried here either: the retry moments are activations,
            // and reacting to failure callbacks would hot-loop a transport
            // that is down anyway.
            return []

        case let .snapshotReceived(version, payload):
            if let applied = state.lastAppliedSnapshotVersion, version <= applied {
                // Stale or duplicate: a whole-replace must never run
                // backwards, and re-applying the same version buys nothing.
                return []
            }
            state.lastAppliedSnapshotVersion = version
            return [.applySnapshot(version: version, payload: payload)]

        case let .digestReceived(ackedSessionIDs, payload):
            // The only way out of the outbox. Ids the outbox does not hold
            // are fine — acks are retained ~30 days phone-side, so most
            // digests re-name sessions long since pruned here.
            state.outbox.removeAll { ackedSessionIDs.contains($0.id) }
            return [.applyDigest(payload: payload)]
        }
    }
}
