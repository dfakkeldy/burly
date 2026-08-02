// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — `FileBackedPhoneSyncStatePersisting`: the JSON round-trip that
// lets `PhoneSyncMachine.State` (and the coordinator's daily-push
// bookkeeping) survive a relaunch without a schema change (house rule: no
// schema changes — see that type's file doc for why this cannot be a new
// `@Model`), plus the m4-04 review round 1 blocker 1 fixes: the primary
// state going missing/unreadable/semantically-invalid must never reset
// `latestSnapshotVersion`/`lastTransferGeneration` (the high-water-mark log
// restores them instead), and must never trap on a hostile value (the
// throwing `Snapshot.makeRuntimeState()` validator instead of
// `PhoneSyncMachine.State`'s own `precondition`s).
import Foundation
import Testing
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("m4-04 — FileBackedPhoneSyncStatePersisting: JSON round-trip + blocker 1")
struct PhoneSyncStatePersistingTests {

    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-phone-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "state.json", directoryHint: .notDirectory)
    }

    private func highWaterURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("highwater.jsonl")
    }

    // MARK: - Ordinary round-trip

    @Test("nothing saved yet reads back nil, not a throw")
    func loadWithNothingSavedReturnsNil() throws {
        let persisting = FileBackedPhoneSyncStatePersisting(url: makeTemporaryURL())
        #expect(try persisting.load() == nil)
    }

    @Test("a saved state round-trips byte-for-byte across a fresh instance — every field, not just the obvious ones")
    func savedStateRoundTripsAcrossAFreshInstance() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let idA = UUID()
        let idB = UUID()
        let machineState = BurlyPhoneSyncMachine.State(
            ackAge: [idA: 12_345, idB: 0],
            lastObservedNow: Date(timeIntervalSince1970: 1_700_000_000),
            pendingStoreConfirmations: [idA: BurlyPhoneSyncMachine.PendingIngest(revision: 3, age: 42)],
            latestSnapshotVersion: 7,
            lastTransferGeneration: 11,
            outstandingSnapshot: BurlyPhoneSyncMachine.SnapshotTransfer(version: 7, generation: 11)
        )
        let runtime = PhoneSyncRuntimeState(
            machineState: machineState,
            lastDailyPushAt: Date(timeIntervalSince1970: 1_699_999_000)
        )

        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)
        let reloaded = try FileBackedPhoneSyncStatePersisting(url: url).load()

        #expect(reloaded?.runtimeState == runtime)
        #expect(reloaded?.recoveredFromCorruption == false)
    }

    @Test("a state with no outstanding snapshot and no pending confirmations round-trips its empty collections correctly")
    func emptyCollectionsRoundTrip() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let runtime = PhoneSyncRuntimeState()
        try FileBackedPhoneSyncStatePersisting(url: url).save(runtime)
        let reloaded = try FileBackedPhoneSyncStatePersisting(url: url).load()

        #expect(reloaded?.runtimeState == runtime)
        #expect(reloaded?.runtimeState.machineState.outstandingSnapshot == nil)
        #expect(reloaded?.runtimeState.machineState.pendingStoreConfirmations.isEmpty == true)
        #expect(reloaded?.runtimeState.lastDailyPushAt == nil)
    }

    @Test("a second save overwrites the first — latest-wins, not accumulating rows in some hidden log")
    func secondSaveOverwritesTheFirst() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 1)
        ))
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 2)
        ))

        let reloaded = try persisting.load()
        #expect(reloaded?.runtimeState.machineState.latestSnapshotVersion == 2)
    }

    @Test("the coordinator's own state survives being reconstructed from a freshly loaded persistence file")
    func coordinatorStateSurvivesReconstruction() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine, startedAt: Fixture.epoch)

        do {
            let persisting = FileBackedPhoneSyncStatePersisting(url: url)
            let coordinator = PhoneSyncCoordinator(
                store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
                statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
            )
            try await coordinator.sessionReceived(BurlySessionPayloadDTO(session: session, needsNamingExercises: []))
        }

        // A fresh coordinator, as a relaunch would construct one, loading
        // from the same file.
        let reloadedPersisting = FileBackedPhoneSyncStatePersisting(url: url)
        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: reloadedPersisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.currentMachineState.ackAge.keys.contains(session.id))
        #expect(relaunched.recoveredFromCorruptState == false)
    }

    // MARK: - Blocker 1: never reset a monotonic identity

    @Test("a primary state file replaced with garbage bytes still restores the monotonic identities from the high-water log — never resets to zero")
    func garbagePrimaryFileRestoresIdentitiesFromHighWaterLog() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 7, lastTransferGeneration: 11)
        ))

        // Corrupt the PRIMARY file only — the high-water log is untouched.
        try Data("not json at all {{{".utf8).write(to: url)

        let reloaded = try #require(try persisting.load())
        #expect(reloaded.recoveredFromCorruption, "a corrupt primary must be a surfaced recovery, not a silent one")
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 7, "must restore from the high-water log, never reset to 0")
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == 11)
        // Every self-healing fact is allowed to reset — the machine's own
        // idempotency absorbs the loss (a lost ack just re-earns via retry).
        #expect(reloaded.runtimeState.machineState.ackAge.isEmpty)
    }

    @Test("a deleted primary file (unreadable, not just malformed) also restores from the high-water log")
    func deletedPrimaryFileRestoresFromHighWaterLog() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 3, lastTransferGeneration: 4)
        ))
        try FileManager.default.removeItem(at: url)

        let reloaded = try #require(try persisting.load())
        #expect(reloaded.recoveredFromCorruption)
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 3)
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == 4)
    }

    @Test("a semantically-corrupt primary (negative snapshot version) throws a catchable error at load time, not a process trap, and still recovers from the high-water log")
    func semanticallyCorruptPrimaryDoesNotTrapAndStillRecovers() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 5, lastTransferGeneration: 2)
        ))

        // A syntactically valid but semantically corrupt `Snapshot` — a
        // negative `latestSnapshotVersion`, which `PhoneSyncMachine.State
        // .init` would `precondition`-trap on if handed directly. Built via
        // `Snapshot`'s direct memberwise init (its normal `init(_:)` can
        // never produce this — `PhoneSyncMachine.State` refuses the value
        // before a real `PhoneSyncRuntimeState` could exist) and encoded
        // with the same `JSONEncoder` production uses, so the *only*
        // hostile thing about this file is the value under test, not an
        // incidentally-wrong hand-written JSON shape (`[UUID: T]`
        // dictionaries encode as flat arrays, not `{}` objects).
        let corruptSnapshot = FileBackedPhoneSyncStatePersisting.Snapshot(
            latestSnapshotVersion: -1,
            lastTransferGeneration: 2
        )
        try JSONEncoder().encode(corruptSnapshot).write(to: url)

        // The call below must not crash the test process — that is the
        // property under test. If `Snapshot.makeRuntimeState()` ever went
        // back to calling `BurlyPhoneSyncMachine.State.init` directly with
        // unvalidated fields, this line would trap instead of returning.
        let reloaded = try #require(try persisting.load())
        #expect(reloaded.recoveredFromCorruption)
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 5, "restored from the high-water log")
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == 2)
    }

    @Test("Snapshot.makeRuntimeState throws PhoneSyncStateCorruptionError for each documented invalid field, rather than trapping")
    func makeRuntimeStateThrowsForEveryInvalidField() throws {
        let sessionID = UUID()

        #expect(throws: PhoneSyncStateCorruptionError.negativeSnapshotVersion(-1)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: -1, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativeTransferGeneration(-2)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: 0, lastTransferGeneration: -2
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativeAckAge(sessionID: sessionID, age: -5)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                ackAge: [sessionID: -5], latestSnapshotVersion: 0, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativePendingAge(sessionID: sessionID, age: -3)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                pendingRevisions: [sessionID: 1], pendingAges: [sessionID: -3],
                latestSnapshotVersion: 0, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
    }

    @Test("the high-water log tolerates its own corruption: a garbled line is skipped, valid lines still contribute to the max")
    func highWaterLogToleratesPartialCorruption() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hwURL = highWaterURL(for: url)

        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        try persisting.save(PhoneSyncRuntimeState(machineState: .init(latestSnapshotVersion: 2, lastTransferGeneration: 1)))
        try persisting.save(PhoneSyncRuntimeState(machineState: .init(latestSnapshotVersion: 4, lastTransferGeneration: 3)))

        // Append a garbled, unparseable line directly, simulating a torn
        // write mid-append — the log's *own* corruption, tolerated
        // per-line rather than aborting the whole read.
        let handle = try FileHandle(forWritingTo: hwURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not valid json\n".utf8))

        // Corrupt the primary too, forcing recovery to depend entirely on
        // the high-water log.
        try Data("garbage".utf8).write(to: url)

        let reloaded = try #require(try persisting.load())
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 4, "the garbled trailing line must not erase the valid max that came before it")
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == 3)
    }

    @Test("recovery never lets the next identity regress below the pre-corruption high-water mark, across a simulated relaunch")
    func identityNeverRegressesAcrossACorruptionAndRelaunch() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try makePhoneStore()

        var lastGeneration = 0
        do {
            let persisting = FileBackedPhoneSyncStatePersisting(url: url)
            let coordinator = PhoneSyncCoordinator(
                store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
                statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
            )
            try await coordinator.applicationDidLaunch()
            try await coordinator.applicationDidLaunch()
            try await coordinator.applicationDidLaunch()
            lastGeneration = coordinator.currentMachineState.lastTransferGeneration
            #expect(lastGeneration == 3)
        }

        // The primary is now corrupted out-of-band (a bad migration, a
        // disk error) — but the high-water log (written on every save,
        // before the primary) is untouched.
        try Data("corrupt".utf8).write(to: url)

        let relaunched = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: FileBackedPhoneSyncStatePersisting(url: url),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )
        #expect(relaunched.recoveredFromCorruptState)
        #expect(relaunched.currentMachineState.lastTransferGeneration == lastGeneration, "must restore at-or-above the true high-water, not reset to 0")

        // And the line keeps moving forward from there, never reusing a
        // generation a live transfer might still be using.
        try await relaunched.applicationDidLaunch()
        #expect(relaunched.currentMachineState.lastTransferGeneration == lastGeneration + 1)
    }
}
