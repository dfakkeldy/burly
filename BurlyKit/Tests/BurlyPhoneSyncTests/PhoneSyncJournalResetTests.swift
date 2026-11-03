// SPDX-License-Identifier: GPL-3.0-or-later
// The phone app's exit from an unrecoverable sync journal (`PhoneSyncHost`'s
// file doc): checked again on the first foreground, reset only if it is
// still unrecoverable then, and left alone when it was only unreadable at
// launch.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlySyncAdapters
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("Phone sync host — an unrecoverable journal is reset in the foreground")
struct PhoneSyncJournalResetTests {
    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-journal-reset-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "phone-sync.journal", directoryHint: .notDirectory)
    }

    private func makeHost(
        persisting: any PhoneSyncStatePersisting,
        session: ResetTestSession
    ) throws -> PhoneSyncHost {
        let store = try makePhoneStore()
        try store.createExercise(Fixture.exercise(name: "Bench Press"))
        return PhoneSyncHost(
            store: store,
            session: session,
            statePersisting: persisting,
            watchSettings: { PhoneWatchSettings() },
            isWatchAppInstalled: { true },
            configuration: .init(
                catalogEditDebounce: .milliseconds(1),
                digestPublishDebounce: .milliseconds(1)
            )
        )
    }

    /// Launch: WCSession activates while the journal is unrecoverable, so
    /// the launch push runs as a no-op.
    private func activate(_ host: PhoneSyncHost, _ session: ResetTestSession) async {
        host.activate()
        session.activationState = .activated
        session.hasContentPending = false
        session.delegate?.transportActivationDidComplete(state: .activated, hasContentPending: false, error: nil)
        await host.flushEvents()
    }

    @Test("a journal still unrecoverable in the foreground is reset, logged, and the launch push goes out")
    func unrecoverableJournalIsResetInForeground() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The first write tore: the file exists and holds no valid record.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"seq":0,"fullRuntimeSta"#.utf8).write(to: url)
        let session = ResetTestSession()
        let host = try makeHost(persisting: FileBackedPhoneSyncStatePersisting(url: url), session: session)
        #expect(host.coordinator.syncStateUnrecoverable)

        await activate(host, session)
        #expect(session.fileTransfers.isEmpty, "quiescent: the launch push sent nothing")

        host.sceneDidBecomeActive()
        #expect(!host.coordinator.syncStateUnrecoverable)
        // The reset is durable: the next launch loads a valid journal.
        #expect(try FileBackedPhoneSyncStatePersisting(url: url).load() != nil)

        await host.journalResetPush?.value
        await host.flushEvents()
        #expect(session.fileTransfers.count == 1, "the launch push runs again after the reset")
    }

    @Test("a journal that reads again in the foreground was only unreadable at launch: nothing is reset")
    func transientlyUnreadableJournalIsLeftAlone() async throws {
        let url = makeTemporaryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileBackedPhoneSyncStatePersisting(url: url).save(.init(machineState: .init(
            latestSnapshotVersion: 900, lastTransferGeneration: 900
        )))
        let journal = try Data(contentsOf: url)
        // A background launch before first unlock cannot read the file.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let session = ResetTestSession()
        let host = try makeHost(persisting: FileBackedPhoneSyncStatePersisting(url: url), session: session)
        #expect(host.coordinator.syncStateUnrecoverable)
        await activate(host, session)

        // The user unlocks and opens the app.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        host.sceneDidBecomeActive()
        host.sceneDidBecomeActive()

        #expect(host.coordinator.syncStateUnrecoverable, "stays quiescent until the next launch loads it")
        #expect(host.journalResetPush == nil)
        #expect(try Data(contentsOf: url) == journal, "the 900/900 identity line is untouched")
        let reloaded = try #require(try FileBackedPhoneSyncStatePersisting(url: url).load())
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 900)
        #expect(session.fileTransfers.isEmpty)
    }

    @Test("a reset that cannot be written leaves sync quiescent and is retried on the next foreground")
    func failedResetIsRetried() async throws {
        let persisting = ScriptedJournalPersisting(failingResets: 1)
        let session = ResetTestSession()
        let host = try makeHost(persisting: persisting, session: session)
        await activate(host, session)

        host.sceneDidBecomeActive()
        #expect(host.coordinator.syncStateUnrecoverable)
        #expect(persisting.resetAttempts == 1)
        #expect(session.fileTransfers.isEmpty)

        host.sceneDidBecomeActive()
        #expect(!host.coordinator.syncStateUnrecoverable)
        #expect(persisting.resetAttempts == 2)
        await host.journalResetPush?.value
        await host.flushEvents()
        #expect(session.fileTransfers.count == 1)

        // Settled: a later foreground neither checks nor resets again.
        host.sceneDidBecomeActive()
        #expect(persisting.resetAttempts == 2)
    }

    @Test("a healthy journal is never reset in the foreground")
    func healthyJournalIsNeverReset() async throws {
        let persisting = ScriptedJournalPersisting(failingResets: 0, healthy: true)
        let session = ResetTestSession()
        let host = try makeHost(persisting: persisting, session: session)
        await activate(host, session)

        host.sceneDidBecomeActive()

        #expect(!host.coordinator.syncStateUnrecoverable)
        #expect(host.journalResetPush == nil)
        #expect(persisting.resetAttempts == 0)
    }
}

/// A journal that does not load until it is reset (unless `healthy`), and
/// whose reset fails `failingResets` times before it succeeds. State is kept
/// in memory.
private final class ScriptedJournalPersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private var remainingFailures: Int
    private var stored: PhoneSyncRuntimeState?
    private(set) var resetAttempts = 0

    init(failingResets: Int, healthy: Bool = false) {
        remainingFailures = failingResets
        stored = healthy ? PhoneSyncRuntimeState() : nil
    }

    func load() throws -> PhoneSyncLoadResult? {
        guard let stored else { throw PhoneSyncStateUnrecoverableError() }
        return PhoneSyncLoadResult(runtimeState: stored, recoveredFromCorruption: false)
    }

    func save(_ state: PhoneSyncRuntimeState) throws {
        guard stored != nil else { throw PhoneSyncStateUnrecoverableError() }
        try validatePhoneSyncIdentityBounds(state)
        stored = state
    }

    func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {
        resetAttempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw POSIXError(.ENOSPC)
        }
        stored = state
    }
}

@MainActor
private final class ResetTestSession: WCSessionTransport {
    weak var delegate: (any WCSessionTransportDelegate)?
    var activationState: WCSessionActivation = .notActivated
    var hasContentPending = true
    var outstandingSessionIDs: Set<UUID> = []
    var receivedApplicationContext: (envelope: Data, metadata: WCSessionTransferMetadata)?
    private(set) var fileTransfers: [WCSessionTransferMetadata] = []

    func activate() {}

    func transferUserInfo(envelope: Data, metadata: WCSessionTransferMetadata) {}

    func updateApplicationContext(envelope: Data, metadata: WCSessionTransferMetadata) throws {}

    func transferFile(
        envelope: Data,
        metadata: WCSessionTransferMetadata
    ) throws -> any WCSessionFileTransferHandle {
        fileTransfers.append(metadata)
        return ResetTestFileTransferHandle()
    }
}

@MainActor
private final class ResetTestFileTransferHandle: WCSessionFileTransferHandle {
    func cancel() {}
}
