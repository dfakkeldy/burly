// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — PhoneSyncTransporting
//
// The seam between this runtime and the actual wire (m4-03's WCSession
// adapter, app-agnostic per that task's brief). `PhoneSyncCoordinator`
// builds the domain-shaped payload from store truth — that part genuinely
// needs `BurlyStore` and cannot live in the transport-agnostic adapter — and
// hands it across this protocol for the bytes to actually move. Production
// wires a conformer backed by m4-03's adapter; this module's own tests use
// an in-memory fake, matching `BurlySyncMachineTests/SyncHarness.swift`'s
// channel stand-ins one layer up the stack.
import Foundation
import BurlySync

/// What the coordinator needs a transport to do with a built snapshot: send
/// it, and cancel a specific outstanding attempt. Digest publication has no
/// equivalent cancel — §5's `updateApplicationContext` is latest-wins by the
/// channel's own nature, so superseding one digest with another is just
/// sending the newer one (see `PhoneDigestPublishing`).
public protocol PhoneSyncTransporting: Sendable {
    /// Starts transferring `payload` under transfer identity `generation` —
    /// the same identity `PhoneSyncMachine.Command.transmitSnapshot`'s
    /// `generation` carries, so the coordinator's later
    /// `.snapshotTransferFinished` echo and this call agree on which
    /// attempt is which (m4-02 review 2, #2).
    ///
    /// `throws` (m4-04 review round 1, major 3): a trigger that only marks
    /// itself "done" after a successful enqueue (the daily push, the
    /// install-flip edge) needs a real failure signal to retry against —
    /// a transport that could never fail made that ordering fix vacuous.
    /// A conformer that genuinely cannot fail to *start* a transfer (most
    /// underlying transports can at least always queue the attempt) may
    /// simply never throw.
    func transmitSnapshot(_ payload: BurlySnapshotPayloadDTO, generation: Int) async throws

    /// Cancels the transfer identified by `(version, generation)` — a
    /// harmless no-op if the transport already finished or lost it (§5
    /// supersession; `PhoneSyncMachine`'s own doc on
    /// `.cancelSnapshotTransfer`). `PhoneSyncCoordinator` treats a thrown
    /// cancellation failure as best-effort and does not let it block the
    /// `transmitSnapshot` that always follows it in the same command batch
    /// — an old transfer failing to cancel must never prevent the new one
    /// from starting.
    func cancelSnapshotTransfer(version: Int, generation: Int) async throws
}

/// The §5 `digest` publish half of the transport seam, kept separate from
/// `PhoneSyncTransporting` because it carries no transfer identity to
/// cancel — `updateApplicationContext` only ever has "the current value",
/// and the coordinator's own `QuietPeriodCoalescer` is what keeps only the
/// latest one ever reaching this call.
public protocol PhoneDigestPublishing: Sendable {
    /// Publishes `payload` as the current §5 digest. Latest-wins at the
    /// channel level — a later call's payload is what the watch reads when
    /// it next observes application context, regardless of delivery order
    /// of the calls themselves.
    func publishDigest(_ payload: BurlyDigestPayloadDTO) async
}
