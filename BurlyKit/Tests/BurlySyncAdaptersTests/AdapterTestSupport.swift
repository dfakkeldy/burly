// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import BurlySyncAdapters

actor RecordingEventSink: WCSessionAdapterEventSink {
    private var events: [WCSessionAdapterEvent] = []

    func receive(_ event: WCSessionAdapterEvent) {
        events.append(event)
    }

    func recordedEvents() -> [WCSessionAdapterEvent] { events }
}

@MainActor
final class FakeFileTransferHandle: WCSessionFileTransferHandle {
    private(set) var cancellationCount = 0

    func cancel() {
        cancellationCount += 1
    }
}

@MainActor
final class FakeWCSessionTransport: WCSessionTransport {
    struct Transfer: Equatable {
        let envelope: Data
        let metadata: WCSessionTransferMetadata
    }

    weak var delegate: (any WCSessionTransportDelegate)?
    var activationState: WCSessionActivation = .notActivated
    var hasContentPending = true
    var outstandingSessionIDs: Set<UUID> = []
    private(set) var activationCount = 0
    private(set) var userInfoTransfers: [Transfer] = []
    private(set) var applicationContexts: [Transfer] = []
    private(set) var fileTransfers: [Transfer] = []
    private(set) var fileHandles: [FakeFileTransferHandle] = []
    var updateApplicationContextError: (any Error)?
    var transferFileError: (any Error)?

    func activate() {
        activationCount += 1
    }

    func transferUserInfo(envelope: Data, metadata: WCSessionTransferMetadata) {
        userInfoTransfers.append(Transfer(envelope: envelope, metadata: metadata))
    }

    func updateApplicationContext(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws {
        if let updateApplicationContextError { throw updateApplicationContextError }
        applicationContexts.append(Transfer(envelope: envelope, metadata: metadata))
    }

    func transferFile(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws -> any WCSessionFileTransferHandle {
        if let transferFileError { throw transferFileError }
        fileTransfers.append(Transfer(envelope: envelope, metadata: metadata))
        let handle = FakeFileTransferHandle()
        fileHandles.append(handle)
        return handle
    }
}

@MainActor
final class FakeSystemRefreshBackgroundTask {
    private(set) var snapshots: [Bool] = []

    func setTaskCompletedWithSnapshot(_ snapshot: Bool) {
        snapshots.append(snapshot)
    }
}

@MainActor
final class FakeRefreshBackgroundTask: WCRefreshBackgroundTask {
    let task: FakeSystemRefreshBackgroundTask

    init(wrapping task: FakeSystemRefreshBackgroundTask = FakeSystemRefreshBackgroundTask()) {
        self.task = task
    }

    var completionID: ObjectIdentifier { ObjectIdentifier(task) }

    var snapshots: [Bool] { task.snapshots }

    func setTaskCompletedWithSnapshot(_ snapshot: Bool) {
        task.setTaskCompletedWithSnapshot(snapshot)
    }
}

let testPayloadKinds = WCSessionPayloadKinds(
    snapshot: "test-snapshot",
    session: "test-session",
    digest: "test-digest"
)

func acceptedTestEnvelope(_ data: Data) -> OpaqueEnvelopeInspection {
    switch String(decoding: data, as: UTF8.self) {
    case "snapshot": .accepted(kind: testPayloadKinds.snapshot)
    case "session": .accepted(kind: testPayloadKinds.session)
    case "digest": .accepted(kind: testPayloadKinds.digest)
    case "future": .heldNeedsAppUpdate(schemaVersion: 2)
    default: .malformed(reason: "test decoder rejected bytes")
    }
}
