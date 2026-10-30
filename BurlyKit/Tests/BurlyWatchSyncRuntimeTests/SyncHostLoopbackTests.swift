// SPDX-License-Identifier: GPL-3.0-or-later
// m4-06 — the app compositions, end to end in one process: a real
// `PhoneSyncHost` and a real `WatchSyncHost`, each over a real store and a
// real `WCSessionAdapter`, joined by two fake WCSessions that a test pumps
// by hand. This is the in-process half of §5 acceptance #2; the paired
// simulators prove the same flow over WatchConnectivity itself.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlyPhoneSync
import BurlySync
import BurlySyncAdapters
@testable import BurlyWatchSyncRuntime

@MainActor
@Suite("m4-06 — phone and watch hosts over a loopback transport")
struct SyncHostLoopbackTests {
    @Test("a phone routine reaches the watch with the phone's settings, and a watch session comes back and is pruned on ack")
    func routineOutSessionBack() async throws {
        let rig = try Rig(settings: PhoneWatchSettings(displayUnit: .pounds, restDefault: 120))
        let bench = ExerciseData(name: "Bench Press", muscleGroups: [.chest], origin: .curated)
        let routine = RoutineData(
            name: "Push",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: bench.id, order: 0, defaultSetCount: 3)],
            updatedAt: .now
        )
        try rig.phone.createExercise(bench)
        try rig.phone.createRoutine(routine)

        try await rig.activateBoth()

        // Launch push: one snapshot file, and a digest for the fresh watch.
        #expect(rig.phoneSession.fileTransfers.count == 1)
        #expect(!rig.phoneSession.applicationContexts.isEmpty)
        await rig.deliverPhoneToWatch()

        #expect(try rig.watch.routine(id: routine.id)?.name == "Push")
        #expect(rig.watchHost.displayUnit == .pounds)
        #expect(rig.watchHost.restDefault == 120)
        #expect(rig.watchHost.workingSetGeneration == 2)

        // A logged session on the watch goes out immediately.
        let session = SessionData(
            routineID: routine.id,
            routineName: routine.name,
            startedAt: .now,
            endedAt: .now,
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: bench.id, order: 0)]
        )
        try rig.watch.createSession(session)
        rig.watchHost.sessionLogged(id: session.id)
        #expect(rig.watchSession.userInfoTransfers.map(\.metadata.sessionID) == [session.id])

        await rig.deliverWatchToPhone()
        #expect(try rig.phone.session(id: session.id)?.routineName == "Push")

        // The phone's digest acknowledges it; the watch prunes it.
        await rig.deliverPhoneToWatch()
        #expect(try rig.watch.session(id: session.id) == nil)
        #expect(try rig.watch.loggedSessionsAwaitingAck().isEmpty)
    }

    @Test("an unacknowledged session is re-sent on app activation unless WatchConnectivity still holds it")
    func outboxRetriesOnActivation() async throws {
        // Logged on an earlier launch and never acknowledged: the host
        // rebuilds its outbox from the store.
        let session = SessionData(startedAt: .now, endedAt: .now, state: .logged, origin: .live, items: [])
        let rig = try Rig(seedWatch: { try $0.createSession(session) })
        try await rig.activateBoth()

        // Activation itself retried the outbox.
        #expect(rig.watchSession.userInfoTransfers.count == 1)

        rig.watchSession.outstandingSessionIDs = [session.id]
        rig.watchHost.appDidBecomeActive()
        #expect(rig.watchSession.userInfoTransfers.count == 1)

        rig.watchSession.outstandingSessionIDs = []
        rig.watchHost.appDidBecomeActive()
        #expect(rig.watchSession.userInfoTransfers.count == 2)
    }

    @Test("a snapshot from a newer schema is held and surfaced, and changes nothing")
    func newerSchemaIsHeld() async throws {
        let rig = try Rig()
        try await rig.activateBoth()
        let future = Data(#"{"schemaVersion":99,"kind":"snapshot","payload":{}}"#.utf8)

        rig.watchSession.delegate?.transportDidReceive(
            channel: .snapshotFile,
            data: future,
            metadata: WCSessionTransferMetadata(
                kind: BurlySyncPayloadKind.snapshot.rawValue,
                snapshot: SnapshotTransferIdentity(version: 9, generation: 1)
            )
        )
        await rig.watchHost.flushEvents()

        #expect(rig.watchHost.heldSchemaVersion == 99)
        #expect(try rig.watch.watchSyncState().lastAppliedSnapshotVersion == nil)
    }

    @Test("a snapshot transfer that cannot start clears the phone's outstanding slot")
    func failedTransferStartIsEchoed() async throws {
        let rig = try Rig()
        rig.phoneSession.transferFileError = LoopbackError()
        try await rig.activateBoth()

        #expect(rig.phoneHost.coordinator.currentMachineState.outstandingSnapshot == nil)
    }

    @Test("a Watch Connectivity background task completes once activation reports nothing pending")
    func backgroundTaskCompletesAfterActivation() async throws {
        let rig = try Rig()
        let task = LoopbackBackgroundTask()
        rig.watchHost.retainBackgroundTask(task)
        #expect(rig.watchHost.retainedBackgroundTaskCount == 1)
        #expect(task.completions.isEmpty)

        try await rig.activateBoth()

        #expect(rig.watchHost.retainedBackgroundTaskCount == 0)
        #expect(task.completions == [false])
    }
}

// MARK: - Rig

@MainActor
private struct Rig {
    let phone: SwiftDataStore
    let watch: SwiftDataStore
    let phoneSession = LoopbackSession()
    let watchSession = LoopbackSession()
    let phoneHost: PhoneSyncHost
    let watchHost: WatchSyncHost

    /// `seedWatch` runs before the watch host exists: what it stores is
    /// what an earlier launch left behind.
    init(
        settings: PhoneWatchSettings = PhoneWatchSettings(),
        seedWatch: (SwiftDataStore) throws -> Void = { _ in }
    ) throws {
        phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        try seedWatch(watch)
        phoneHost = PhoneSyncHost(
            store: phone,
            session: phoneSession,
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            watchSettings: { settings },
            isWatchAppInstalled: { true },
            configuration: .init(
                catalogEditDebounce: .milliseconds(1),
                digestPublishDebounce: .milliseconds(1)
            )
        )
        watchHost = try WatchSyncHost(store: watch, session: watchSession)
    }

    func activateBoth() async throws {
        phoneHost.activate()
        watchHost.activate()
        for session in [phoneSession, watchSession] {
            session.activationState = .activated
            session.hasContentPending = false
            session.delegate?.transportActivationDidComplete(
                state: .activated,
                hasContentPending: false,
                error: nil
            )
        }
        await settle()
    }

    /// Delivers everything the phone has queued since the last call, in
    /// channel order: the newest snapshot file, then the newest context.
    func deliverPhoneToWatch() async {
        for transfer in phoneSession.takeFileTransfers() {
            watchSession.delegate?.transportDidReceive(
                channel: .snapshotFile,
                data: transfer.envelope,
                metadata: transfer.metadata
            )
            if let identity = transfer.metadata.snapshot {
                phoneSession.delegate?.transportSnapshotTransferDidFinish(identity: identity, error: nil)
            }
        }
        if let context = phoneSession.takeApplicationContexts().last {
            watchSession.delegate?.transportDidReceive(
                channel: .digestApplicationContext,
                data: context.envelope,
                metadata: context.metadata
            )
        }
        await settle()
    }

    func deliverWatchToPhone() async {
        for transfer in watchSession.takeUserInfoTransfers() {
            phoneSession.delegate?.transportDidReceive(
                channel: .sessionUserInfo,
                data: transfer.envelope,
                metadata: transfer.metadata
            )
        }
        await settle()
    }

    /// Runs every queued adapter event and debounced digest to completion.
    private func settle() async {
        await phoneHost.flushEvents()
        await watchHost.flushEvents()
        await phoneHost.coordinator.drainPendingDebounces()
        await phoneHost.flushEvents()
        await watchHost.flushEvents()
    }
}

@MainActor
private final class LoopbackSession: WCSessionTransport {
    struct Transfer {
        let envelope: Data
        let metadata: WCSessionTransferMetadata
    }

    weak var delegate: (any WCSessionTransportDelegate)?
    var activationState: WCSessionActivation = .notActivated
    var hasContentPending = true
    var outstandingSessionIDs: Set<UUID> = []
    var transferFileError: (any Error)?
    private(set) var userInfoTransfers: [Transfer] = []
    private(set) var applicationContexts: [Transfer] = []
    private(set) var fileTransfers: [Transfer] = []

    func activate() {}

    func transferUserInfo(envelope: Data, metadata: WCSessionTransferMetadata) {
        userInfoTransfers.append(Transfer(envelope: envelope, metadata: metadata))
    }

    func updateApplicationContext(envelope: Data, metadata: WCSessionTransferMetadata) throws {
        applicationContexts.append(Transfer(envelope: envelope, metadata: metadata))
    }

    func transferFile(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws -> any WCSessionFileTransferHandle {
        if let transferFileError { throw transferFileError }
        fileTransfers.append(Transfer(envelope: envelope, metadata: metadata))
        return LoopbackFileTransferHandle()
    }

    func takeFileTransfers() -> [Transfer] {
        defer { fileTransfers = [] }
        return fileTransfers
    }

    func takeApplicationContexts() -> [Transfer] {
        defer { applicationContexts = [] }
        return applicationContexts
    }

    func takeUserInfoTransfers() -> [Transfer] {
        defer { userInfoTransfers = [] }
        return userInfoTransfers
    }
}

@MainActor
private final class LoopbackFileTransferHandle: WCSessionFileTransferHandle {
    func cancel() {}
}

@MainActor
private final class LoopbackBackgroundTask: WCRefreshBackgroundTask {
    private(set) var completions: [Bool] = []

    var completionID: ObjectIdentifier { ObjectIdentifier(self) }

    func setTaskCompletedWithSnapshot(_ snapshot: Bool) {
        completions.append(snapshot)
    }
}

private struct LoopbackError: Error {}
