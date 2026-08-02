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
        // m4-04 review round 2, finding 2: the upper bound, not just the
        // lower one — a hostile-but-syntactically-valid `Int.max` used to
        // sail through this same validator and trap on the next
        // `PhoneSyncMachine` `+= 1`.
        #expect(throws: PhoneSyncStateCorruptionError.snapshotVersionTooLarge(Int.max)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: Int.max, lastTransferGeneration: 0
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.negativeTransferGeneration(-2)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: 0, lastTransferGeneration: -2
            ).makeRuntimeState()
        }
        #expect(throws: PhoneSyncStateCorruptionError.transferGenerationTooLarge(Int.max)) {
            _ = try FileBackedPhoneSyncStatePersisting.Snapshot(
                latestSnapshotVersion: 0, lastTransferGeneration: Int.max
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

    // MARK: - Round 2, finding 2: an Int.max high-water record must not trap downstream

    @Test("round 2, finding 2 — a high-water line containing Int.max is skipped as corrupt, not restored and later trapped")
    func highWaterLineWithIntMaxIsSkippedNotRestored() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hwURL = highWaterURL(for: url)

        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        // A legitimate, small value first...
        try persisting.save(PhoneSyncRuntimeState(machineState: .init(latestSnapshotVersion: 3, lastTransferGeneration: 2)))

        // ...then a hostile line appended directly: `Int.max` for both
        // fields. Before this fix, the log's only bound was `>= 0`, so
        // this line WON the max — reconstructing a state at `Int.max`,
        // which traps the very next `.catalogChanged` or push
        // (`PhoneSyncMachine`'s `+= 1`).
        let handle = try FileHandle(forWritingTo: hwURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var hostileLine = try JSONEncoder().encode(["version": Int.max, "generation": Int.max])
        hostileLine.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: hostileLine)

        // Corrupt the primary too, forcing recovery to depend entirely on
        // the (now partially-hostile) high-water log.
        try Data("garbage".utf8).write(to: url)

        let reloaded = try #require(try persisting.load())
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == 3, "the Int.max line must be skipped as corrupt, leaving the last legitimate value")
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == 2)
    }

    // MARK: - Round 3, §2: the ceiling binds on the WRITE path, not only on read

    @Test("round 3, §2 — save() refuses a snapshot version past the ceiling before writing ANY byte: primary and high-water log both stay at the last valid state")
    func saveRefusesOutOfRangeSnapshotVersion() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hwURL = highWaterURL(for: url)

        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: 3, lastTransferGeneration: 2)
        ))
        let highWaterBytesBefore = try Data(contentsOf: hwURL)
        let primaryBytesBefore = try Data(contentsOf: url)

        // Pre-fix, this wrote and would later be transmitted; only the NEXT
        // relaunch rejected it — restoring 3/2 and setting up the ceiling+1
        // value for reuse. Post-fix it is refused here, before any write.
        #expect(throws: PhoneSyncIdentityOverflowError.snapshotVersionOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try persisting.save(PhoneSyncRuntimeState(
                machineState: .init(latestSnapshotVersion: maximumPhoneSyncIdentity + 1, lastTransferGeneration: 2)
            ))
        }

        #expect(try Data(contentsOf: hwURL) == highWaterBytesBefore, "the out-of-range identity must not reach even the high-water log")
        #expect(try Data(contentsOf: url) == primaryBytesBefore, "nor the primary file")
        #expect(try persisting.load()?.runtimeState.machineState.latestSnapshotVersion == 3)
    }

    @Test("round 3, §2 — save() refuses a transfer generation past the ceiling, in BOTH conformers (file-backed and in-memory)")
    func saveRefusesOutOfRangeTransferGenerationInBothConformers() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outOfRange = PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: 1, lastTransferGeneration: maximumPhoneSyncIdentity + 1)
        )

        let fileBacked = FileBackedPhoneSyncStatePersisting(url: url)
        #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try fileBacked.save(outOfRange)
        }

        let inMemory = InMemoryPhoneSyncStatePersisting()
        #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try inMemory.save(outOfRange)
        }
        #expect(try inMemory.load() == nil, "the refused state must not have been stored")
    }

    @Test("round 3, §2 — the bound is inclusive and consistent across save and load: a state exactly AT the ceiling round-trips")
    func stateExactlyAtTheCeilingRoundTrips() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: .init(
                latestSnapshotVersion: maximumPhoneSyncIdentity,
                lastTransferGeneration: maximumPhoneSyncIdentity
            )
        ))

        let reloaded = try #require(try persisting.load())
        #expect(reloaded.recoveredFromCorruption == false, "at-the-ceiling is valid on read too — the same inclusive bound everywhere")
        #expect(reloaded.runtimeState.machineState.latestSnapshotVersion == maximumPhoneSyncIdentity)
        #expect(reloaded.runtimeState.machineState.lastTransferGeneration == maximumPhoneSyncIdentity)
    }

    @Test("round 3, §2 — a machine increment past the ceiling is refused at persist time: the out-of-range identity is neither transmitted nor persisted")
    func incrementPastCeilingNeverReachesTransportOrDisk() async throws {
        // A legitimately persisted state whose generation sits exactly at
        // the ceiling — the next push increments past it.
        let persisting = InMemoryPhoneSyncStatePersisting(PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: 1, lastTransferGeneration: maximumPhoneSyncIdentity)
        ))
        let transport = FakeTransport()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: ManualTriggerScheduler()
        )

        // `.snapshotPushTriggered` bumps the generation to ceiling+1; the
        // save inside `deliver(_:)` must throw BEFORE any command executes
        // (persist-before-execute), so nothing reaches the transport.
        await #expect(throws: PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(maximumPhoneSyncIdentity + 1)) {
            try await coordinator.applicationDidLaunch()
        }

        #expect(await transport.transmissions.isEmpty, "the out-of-range identity must never be handed to the transport")
        #expect(await transport.cancellations.isEmpty)
        #expect(
            try persisting.load()?.runtimeState.machineState.lastTransferGeneration == maximumPhoneSyncIdentity,
            "the persisted state still holds the pre-increment value — nothing out-of-range on disk to be 'restored around' later"
        )
    }

    @Test("round 3, §2 — a catalog edit at the version ceiling surfaces the overflow on lastCatalogPushFailure and transmits nothing")
    func catalogEditAtVersionCeilingSurfacesOverflowWithoutTransmitting() async throws {
        let persisting = InMemoryPhoneSyncStatePersisting(PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: maximumPhoneSyncIdentity, lastTransferGeneration: 1)
        ))
        let transport = FakeTransport()
        let scheduler = ManualTriggerScheduler()
        let coordinator = PhoneSyncCoordinator(
            store: try makePhoneStore(), transport: transport, digestPublisher: FakeDigestPublisher(),
            statePersisting: persisting, clock: TestClock(), scheduler: scheduler,
            // No retries: an overflow is deterministic — retrying it cannot
            // succeed, and zero retries keeps this pin free of untracked
            // retry tasks.
            configuration: .init(catalogEditDebounce: .seconds(1), digestPublishDebounce: .seconds(1), catalogPushRetryCount: 0)
        )

        await coordinator.catalogDidChange()
        _ = await scheduler.waitForFreshWaiter(excluding: [])
        scheduler.advance(by: .seconds(1))
        await coordinator.drainPendingDebounces()

        #expect(await transport.transmissions.isEmpty, "the overflowed version must never be transmitted")
        #expect(coordinator.lastCatalogPushFailure as? PhoneSyncIdentityOverflowError != nil, "the overflow is surfaced like every other catalog-push failure")
        #expect(
            try persisting.load()?.runtimeState.machineState.latestSnapshotVersion == maximumPhoneSyncIdentity,
            "the persisted state still holds the at-ceiling value"
        )
    }

    // MARK: - Round 2, finding 1: "both unreadable" must not degrade to zero

    @Test("round 2, finding 1 — both files genuinely absent is a clean first launch, not a recovery")
    func bothFilesAbsentIsACleanFirstLaunch() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        #expect(try persisting.load() == nil, "neither file has ever existed — zero is correct here, not a recovery")
    }

    @Test("round 2, finding 1 — primary AND high-water log both unreadable throws an unrecoverable error rather than silently resetting to zero")
    func primaryAndHighWaterBothUnreadableIsUnrecoverable() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hwURL = highWaterURL(for: url)

        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        try persisting.save(PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(latestSnapshotVersion: 9, lastTransferGeneration: 6)
        ))

        // Corrupt BOTH — the primary undecodable garbage, the high-water
        // log's only line unparseable. Before this fix, the high-water
        // read degraded to `(0, 0)` here indistinguishably from "never
        // written," and `load()` silently reconstructed a state at zero —
        // ready to reuse generation 1 next and regress the snapshot
        // version the watch had already seen at 9.
        try Data("not json {{{".utf8).write(to: url)
        try Data("also not json {{{".utf8).write(to: hwURL)

        #expect(throws: PhoneSyncStateUnrecoverableError()) {
            _ = try persisting.load()
        }
    }

    @Test("round 2, finding 1 — a present-but-corrupt high-water log alongside an absent primary is also unrecoverable, not treated as first launch")
    func highWaterCorruptWithNoPrimaryIsUnrecoverable() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hwURL = highWaterURL(for: url)

        // Write ONLY a corrupt high-water log; no primary was ever written
        // at this path — e.g. a crash between the log append and the
        // primary write on the very first save. The log's mere presence
        // means this is NOT a genuine first launch, and must not be
        // conflated with that case.
        try FileManager.default.createDirectory(at: hwURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage\n".utf8).write(to: hwURL)

        let persisting = FileBackedPhoneSyncStatePersisting(url: url, highWaterURL: hwURL)
        #expect(throws: PhoneSyncStateUnrecoverableError()) {
            _ = try persisting.load()
        }
    }

    @Test("round 2, finding 1 — PhoneSyncCoordinator surfaces the unrecoverable case distinctly and still constructs safely")
    func coordinatorSurfacesSyncStateUnrecoverable() async throws {
        struct AlwaysUnrecoverableStatePersisting: PhoneSyncStatePersisting {
            func load() throws -> PhoneSyncLoadResult? { throw PhoneSyncStateUnrecoverableError() }
            func save(_ state: PhoneSyncRuntimeState) throws {}
        }

        let store = try makePhoneStore()
        let coordinator = PhoneSyncCoordinator(
            store: store, transport: FakeTransport(), digestPublisher: FakeDigestPublisher(),
            statePersisting: AlwaysUnrecoverableStatePersisting(),
            clock: TestClock(), scheduler: ManualTriggerScheduler()
        )

        #expect(coordinator.syncStateUnrecoverable, "the specific 'both sources exhausted' case must be distinctly flagged")
        #expect(coordinator.recoveredFromCorruptState, "still a corruption recovery in the broader sense")
        #expect(coordinator.currentMachineState == BurlyPhoneSyncMachine.State(), "constructs a safe, functional fresh state rather than crashing or refusing to initialize")
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
