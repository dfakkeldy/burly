// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BurlySyncAdapters

@Suite("WCSession command and callback adapter")
struct WCSessionAdapterTests {
    @Test("watch sessions use transferUserInfo with opaque bytes and identity")
    @MainActor
    func transmitSession() {
        let session = FakeWCSessionTransport()
        let sink = RecordingEventSink()
        let adapter = makeAdapter(session: session, sink: sink)
        let id = UUID()
        let data = Data("session".utf8)

        adapter.execute(.transmitSession(id: id, envelope: data))

        #expect(session.userInfoTransfers == [
            .init(
                envelope: data,
                metadata: WCSessionTransferMetadata(kind: testPayloadKinds.session, sessionID: id)
            )
        ])
    }

    @Test("digest uses latest-wins application context")
    @MainActor
    func publishDigest() {
        let session = FakeWCSessionTransport()
        let adapter = makeAdapter(session: session)
        let first = Data("first".utf8)
        let latest = Data("latest".utf8)

        adapter.execute(.publishDigest(envelope: first))
        adapter.execute(.publishDigest(envelope: latest))

        #expect(session.applicationContexts.map(\.envelope) == [first, latest])
        #expect(session.applicationContexts.allSatisfy {
            $0.metadata.kind == testPayloadKinds.digest
        })
    }

    @Test("newer snapshot cancels older transfer and exact cancellation uses generation")
    @MainActor
    func snapshotSupersessionAndExactCancellation() {
        let session = FakeWCSessionTransport()
        let adapter = makeAdapter(session: session)
        let old = SnapshotTransferIdentity(version: 4, generation: 1)
        let live = SnapshotTransferIdentity(version: 5, generation: 2)
        let sameVersionReplacement = SnapshotTransferIdentity(version: 5, generation: 3)

        adapter.execute(.transmitSnapshot(identity: old, envelope: Data("old".utf8)))
        let oldHandle = session.fileHandles[0]
        adapter.execute(.transmitSnapshot(identity: live, envelope: Data("live".utf8)))
        #expect(oldHandle.cancellationCount == 1)

        adapter.execute(.transmitSnapshot(
            identity: sameVersionReplacement,
            envelope: Data("replacement".utf8)
        ))
        #expect(session.fileHandles[1].cancellationCount == 0)

        adapter.execute(.cancelSnapshotTransfer(identity: live))
        #expect(session.fileHandles[1].cancellationCount == 1)
        #expect(session.fileHandles[2].cancellationCount == 0)
    }

    @Test("same-identity snapshot retransmit cancels the prior handle before replacement")
    @MainActor
    func sameIdentitySnapshotRetransmit() {
        let session = FakeWCSessionTransport()
        let adapter = makeAdapter(session: session)
        let identity = SnapshotTransferIdentity(version: 5, generation: 2)

        adapter.execute(.transmitSnapshot(identity: identity, envelope: Data("first".utf8)))
        let firstHandle = session.fileHandles[0]

        adapter.execute(.transmitSnapshot(identity: identity, envelope: Data("retry".utf8)))
        let replacementHandle = session.fileHandles[1]

        #expect(firstHandle.cancellationCount == 1)
        #expect(replacementHandle.cancellationCount == 0)

        adapter.execute(.cancelSnapshotTransfer(identity: identity))
        #expect(firstHandle.cancellationCount == 1)
        #expect(replacementHandle.cancellationCount == 1)
    }

    @Test("snapshot finish echoes version and generation without delivery claim")
    @MainActor
    func snapshotFinishFact() async {
        let session = FakeWCSessionTransport()
        let sink = RecordingEventSink()
        let adapter = makeAdapter(session: session, sink: sink)
        let identity = SnapshotTransferIdentity(version: 9, generation: 41)
        let error = WCSessionTransportError(domain: "WCErrorDomain", code: 7014, description: "failed")

        adapter.transportSnapshotTransferDidFinish(identity: identity, error: error)
        await adapter.flushEvents()

        #expect(await sink.recordedEvents() == [
            .snapshotTransferFinished(identity: identity, reportedSuccess: false, error: error)
        ])
    }

    @Test("session finish remains a transport callback in success and failure")
    @MainActor
    func sessionFinishFact() async {
        let sink = RecordingEventSink()
        let adapter = makeAdapter(sink: sink)
        let id = UUID()
        let error = WCSessionTransportError(domain: "WCErrorDomain", code: 1, description: "offline")

        adapter.transportSessionTransferDidFinish(id: id, error: nil)
        adapter.transportSessionTransferDidFinish(id: id, error: error)
        await adapter.flushEvents()

        #expect(await sink.recordedEvents() == [
            .sessionTransferFinished(id: id, reportedSuccess: true, error: nil),
            .sessionTransferFinished(id: id, reportedSuccess: false, error: error)
        ])
    }

    @Test("activation reports queued sessions regardless of reachability")
    @MainActor
    func activationQueueDrainFact() async {
        let session = FakeWCSessionTransport()
        let queued = Set([UUID(), UUID()])
        session.outstandingSessionIDs = queued
        let sink = RecordingEventSink()
        let adapter = makeAdapter(session: session, sink: sink)

        adapter.transportReachabilityDidChange(false)
        adapter.transportActivationDidComplete(
            state: .activated,
            hasContentPending: false,
            error: nil
        )
        await adapter.flushEvents()

        #expect(await sink.recordedEvents() == [
            .reachabilityChanged(false),
            .activationCompleted(
                state: .activated,
                alreadyQueuedSessionIDs: queued,
                error: nil
            )
        ])
    }

    @Test("opaque inspection surfaces accepted, held, malformed, and wrong-kind outcomes")
    @MainActor
    func envelopeOutcomes() async {
        let sink = RecordingEventSink()
        let adapter = makeAdapter(sink: sink)
        let metadata = WCSessionTransferMetadata(kind: testPayloadKinds.snapshot)

        adapter.transportDidReceive(
            channel: .snapshotFile,
            data: Data("snapshot".utf8),
            metadata: metadata
        )
        adapter.transportDidReceive(
            channel: .snapshotFile,
            data: Data("future".utf8),
            metadata: metadata
        )
        adapter.transportDidReceive(
            channel: .snapshotFile,
            data: Data("bad".utf8),
            metadata: metadata
        )
        adapter.transportDidReceive(
            channel: .snapshotFile,
            data: Data("session".utf8),
            metadata: metadata
        )
        await adapter.flushEvents()

        #expect(await sink.recordedEvents() == [
            .envelopeReceived(
                channel: .snapshotFile,
                data: Data("snapshot".utf8),
                metadata: metadata
            ),
            .envelopeHeld(
                channel: .snapshotFile,
                data: Data("future".utf8),
                schemaVersion: 2,
                metadata: metadata
            ),
            .envelopeMalformed(
                channel: .snapshotFile,
                data: Data("bad".utf8),
                reason: .inspectorRejected("test decoder rejected bytes"),
                metadata: metadata
            ),
            .envelopeMalformed(
                channel: .snapshotFile,
                data: Data("session".utf8),
                reason: .unexpectedKind(
                    expected: testPayloadKinds.snapshot,
                    actual: testPayloadKinds.session
                ),
                metadata: metadata
            )
        ])
    }

    @Test("adapter background task follows activation plus aggregate pending state")
    @MainActor
    func adapterBackgroundTaskInvariant() {
        let session = FakeWCSessionTransport()
        session.activationState = .inactive
        session.hasContentPending = true
        let adapter = makeAdapter(session: session)
        let tasks = (0..<32).map { _ in FakeRefreshBackgroundTask() }

        tasks.forEach(adapter.retainBackgroundTask)
        adapter.transportSessionStateDidChange(
            activationState: .activated,
            hasContentPending: true
        )
        adapter.transportSnapshotTransferDidFinish(
            identity: SnapshotTransferIdentity(version: 1, generation: 1),
            error: nil
        )
        adapter.transportSessionTransferDidFinish(id: UUID(), error: nil)
        #expect(tasks.allSatisfy { $0.snapshots.isEmpty })
        #expect(adapter.retainedBackgroundTaskCount == tasks.count)

        adapter.transportSessionStateDidChange(
            activationState: .activated,
            hasContentPending: false
        )
        #expect(tasks.allSatisfy { $0.snapshots == [false] })
        #expect(adapter.retainedBackgroundTaskCount == 0)
    }

    @MainActor
    private func makeAdapter(
        session: FakeWCSessionTransport = FakeWCSessionTransport(),
        sink: RecordingEventSink = RecordingEventSink()
    ) -> WCSessionAdapter {
        WCSessionAdapter(
            session: session,
            eventSink: sink,
            payloadKinds: testPayloadKinds,
            inspectEnvelope: acceptedTestEnvelope
        )
    }
}
