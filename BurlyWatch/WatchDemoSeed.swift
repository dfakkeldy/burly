// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic watch-store scenarios for BurlyWatchUITests
// (Scripts/acceptance-sim.sh). Debug-only, and driven entirely by an
// XCUITest launch-environment variable -- a real device launch never sets
// it and always falls through to the on-device store (BurlyWatchApp.swift).
//
// BurlySync's snapshot/digest transport (spec §5) is a later milestone, so
// today the ONLY way routines exist in the watch store is this seed. It
// stands in for "a snapshot + digest already arrived from the phone" so the
// routine-list and "Empty session" (§2) states can be exercised on the
// simulator before that transport is built.

import Foundation
import BurlyCore
import BurlyPersistence

#if DEBUG
@MainActor
enum WatchDemoSeed {
    /// Matched literally (not shared code) by BurlyWatchUITests.swift -- the
    /// UI test target runs out-of-process and can only reach this app
    /// through `XCUIApplication.launchEnvironment`.
    static let environmentKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    /// Optional companion key (m2-03 review findings 6-9): names a
    /// `FaultInjectingStore.Fault` to wrap the scenario's store with, so
    /// BurlyWatchUITests can exercise the save-failure recovery paths --
    /// blocking retry UI, no success haptic on failure, Finish/Discard/
    /// placeholder-creation failure handling -- deterministically, without
    /// a real storage fault (which cannot be induced reliably in a UI
    /// test). Ignored unless `environmentKey` is also present and
    /// recognized.
    static let faultEnvironmentKey = "BURLY_WATCH_UI_TEST_FAULT"
    /// How many of the faulting method's calls succeed before failures
    /// start (e.g. 1 lets Start's own `saveActiveSession` through so the
    /// logging screen can be reached before a later save fails).
    /// Default 1 when unset.
    static let faultSuccessesEnvironmentKey = "BURLY_WATCH_UI_TEST_FAULT_SUCCESSES"
    /// How many consecutive failures the fault produces before calls start
    /// succeeding again, so a test can prove Retry recovers. Default 1
    /// when unset.
    static let faultCountEnvironmentKey = "BURLY_WATCH_UI_TEST_FAULT_COUNT"

    /// Names a unique on-disk store for this launch (m2-06), instead of the
    /// fresh `.inMemory` store every other scenario gets. Every scenario's
    /// store is deliberately memory-only, which vanishes the moment the
    /// process does -- exactly why `XCUIApplication.terminate()` cannot
    /// prove crash recovery against it. This is the one seam that lets a
    /// UI test open the *same* store across the `terminate()`/`launch()`
    /// boundary a real kill-and-relaunch performs, so BurlyWatchUITests can
    /// drive spec §2 acceptance #4 / §3 acceptance #3 through real UI taps
    /// -- Start, log a set, kill, relaunch, Resume -- rather than only
    /// through `BurlyPersistenceTests`' `reopened`-store fixtures.
    ///
    /// The value is a bare token, never a path: this app process and the
    /// XCUITest runner process are different sandboxed processes, and a
    /// filesystem path the runner computed for itself is not guaranteed
    /// writable from here. `storeLocation()` below turns the token into a
    /// URL using *this* process's own `FileManager.temporaryDirectory`, so
    /// the store opens the same way the real on-device store does (a file
    /// this app's own container can always write), just at a disposable,
    /// per-test-run location instead of the shipping one. A test sets this
    /// once, before either `launch()` call, so both launches derive the
    /// identical URL and reopen the same file.
    static let storeTokenEnvironmentKey = "BURLY_WATCH_UI_TEST_STORE_TOKEN"

    enum Scenario: String {
        /// Two routines built from the shipped catalog seed (§9); one has a
        /// logged session so its row exercises "last done N days ago," the
        /// other stays "Never done."
        case routines
        /// A guaranteed-empty, isolated store -- the §5 fresh-install case,
        /// independent of whatever the on-device default store holds.
        case empty
        /// Deliberately fails during construction (m2-01 review finding
        /// 2.1). Exists so BurlyWatchUITests can drive the fail-closed path
        /// end to end: a recognized scenario whose seed cannot be built
        /// must surface as an error state, not fall through to the
        /// on-device store and not render a silently empty/sparse fixture.
        case brokenSeed
        /// `.routines`, plus a *second*, already-`.active` session left in
        /// flight for Push/Pull (m2-03 review finding 1, blocker). Exists
        /// so BurlyWatchUITests can drive a second `Start` into the §4
        /// finish-or-discard recovery choice instead of an unsaved logging
        /// screen -- see `SessionConflictView`.
        case activeConflict
    }

    /// Thrown by a recognized scenario's seed construction. Never converted
    /// to `nil` by `requestedStore()` -- see its doc.
    enum SeedError: Error, Equatable {
        /// `.brokenSeed` was requested; this scenario exists only to be
        /// unbuildable.
        case intentionallyBroken
        /// The bundled catalog no longer contains an exercise the
        /// `.routines` fixture requires by name (m2-01 review finding 2.2).
        /// A renamed or removed catalog exercise is a fixture/catalog
        /// contract violation, not "no routines yet" -- it must not render
        /// as the ordinary empty-store waiting state.
        case catalogMissingExercise(name: String)
        /// The launch-environment key was present but its raw value didn't
        /// match any `Scenario` case -- a typo on either side of the
        /// app/test boundary (m2-03 review finding 12, mirroring
        /// BurlyPhone's PhoneDemoSeed fix, m5-01 review round 2 finding 2).
        /// This is distinct from the key being absent: an absent key
        /// legitimately falls through to the on-device store, but a
        /// present-and-wrong value must not -- the same fail-closed
        /// posture as `.intentionallyBroken` and
        /// `.catalogMissingExercise`, just for a mistake one step earlier.
        case unrecognizedScenario(String)
    }

    /// `nil` **only** when the launch-environment key is absent entirely,
    /// so the caller falls through to the real on-device store.
    ///
    /// Once the key is present, this fails **closed**, in two separate ways
    /// (m2-03 review finding 12; mirrors BurlyPhone's PhoneDemoSeed fix):
    ///
    /// - the raw value doesn't match any `Scenario` case (a typo) -- comes
    ///   back as `.failure(.unrecognizedScenario(raw))`;
    /// - a recognized scenario's seed construction throws (m2-01 review
    ///   finding 2.1) -- comes back as `.failure(error)`.
    ///
    /// The original bug collapsed both of those into the same `nil` the
    /// absent-key case returns, via `guard let raw = ..., let scenario =
    /// Scenario(rawValue: raw) else { return nil }` -- a typo'd scenario
    /// name silently fell through to the real on-device store exactly like
    /// the pre-fix `try?` shape did for a broken fixture. Splitting the two
    /// `guard`s is what keeps "the key was set to *something*" from ever
    /// resolving to "the key wasn't set."
    static func requestedStore() -> Result<BurlyStore, Error>? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else {
            return nil
        }
        guard let scenario = Scenario(rawValue: raw) else {
            return .failure(SeedError.unrecognizedScenario(raw))
        }
        do {
            let store = try makeStore(for: scenario)
            return .success(applyingFaultIfRequested(to: store))
        } catch {
            return .failure(error)
        }
    }

    /// Wraps `store` in a `FaultInjectingStore` when `faultEnvironmentKey`
    /// names a recognized fault -- otherwise returns `store` untouched. An
    /// unrecognized or absent fault name is simply ignored: the fault axis
    /// is a test-only addition to a scenario, not a scenario of its own, so
    /// it does not get the same fail-closed treatment `Scenario` does.
    private static func applyingFaultIfRequested(to store: SwiftDataStore) -> BurlyStore {
        let env = ProcessInfo.processInfo.environment
        guard
            let faultRaw = env[faultEnvironmentKey],
            let fault = FaultInjectingStore.Fault(rawValue: faultRaw)
        else {
            return store
        }
        let successes = env[faultSuccessesEnvironmentKey].flatMap(Int.init) ?? 1
        let count = env[faultCountEnvironmentKey].flatMap(Int.init) ?? 1
        return FaultInjectingStore(
            wrapping: store,
            fault: fault,
            successesBeforeFailing: successes,
            failuresToProduce: count
        )
    }

    private static func makeStore(for scenario: Scenario) throws -> SwiftDataStore {
        guard scenario != .brokenSeed else {
            throw SeedError.intentionallyBroken
        }
        let store = try SwiftDataStore(kind: .watch, at: storeLocation())
        switch scenario {
        case .routines:
            try seedRoutinesIfNeeded(into: store)
        case .activeConflict:
            try seedRoutinesIfNeeded(into: store)
            try seedActiveConflictIfNeeded(into: store)
        case .empty, .brokenSeed:
            break
        }
        return store
    }

    /// `.inMemory` (every scenario's original behavior) unless
    /// `storeTokenEnvironmentKey` names a token -- see that key's doc for
    /// why this is a token turned into a URL here, not a URL handed in
    /// directly.
    private static func storeLocation() -> BurlyStoreLocation {
        guard
            let token = ProcessInfo.processInfo.environment[storeTokenEnvironmentKey],
            !token.isEmpty
        else {
            return .inMemory
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BurlyWatchUITest-\(token).store", directoryHint: .notDirectory)
        return .file(url)
    }

    /// Idempotent wrapper around `seedRoutines` (m2-06): a file-backed store
    /// reopened after `app.terminate()` / `app.launch()` already has these
    /// rows from the previous launch, and re-running `createRoutine`
    /// against them would throw `.duplicateID`. `hasRoutines()` (m5-01,
    /// bounded existence check) is what lets the same scenario name mean
    /// "seed fresh" on a store's first launch and "leave what's already
    /// there" on every launch after -- exactly the semantics a real device
    /// relaunch has (nothing re-seeds an existing store). A no-op for every
    /// `.inMemory` call site (existing tests): a fresh in-memory store is
    /// always empty, so this always seeds there, same as before.
    private static func seedRoutinesIfNeeded(into store: SwiftDataStore) throws {
        guard try !store.hasRoutines() else { return }
        try seedRoutines(into: store)
    }

    /// Same idempotency as `seedRoutinesIfNeeded`, for the second scenario
    /// that seeds into a store this file might reopen.
    private static func seedActiveConflictIfNeeded(into store: SwiftDataStore) throws {
        guard try store.resumableActiveSession() == nil else { return }
        try seedActiveConflict(into: store)
    }

    private static func seedRoutines(into store: SwiftDataStore) throws {
        let seed = try SeedLoader.applyBundled(to: store)
        func exerciseID(named name: String) throws -> UUID {
            guard let id = seed.exercises.first(where: { $0.name == name })?.id else {
                // Catalog content changed: report it rather than leaving the
                // demo sparse (m2-01 review finding 2.2) -- a silently
                // routine-less store here renders as "Waiting for iPhone,"
                // indistinguishable from a real fresh install.
                throw SeedError.catalogMissingExercise(name: name)
            }
            return id
        }

        let squatID = try exerciseID(named: "Back Squat")
        let benchID = try exerciseID(named: "Barbell Bench Press")
        let pullUpID = try exerciseID(named: "Pull-Up")

        let legDay = RoutineData(
            name: "Leg Day",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: squatID, order: 0)],
            updatedAt: .now
        )
        let pushPull = RoutineData(
            name: "Push/Pull",
            orderIndex: 1,
            items: [
                RoutineItemData(exerciseID: benchID, order: 0),
                RoutineItemData(exerciseID: pullUpID, order: 1)
            ],
            updatedAt: .now
        )
        try store.createRoutine(legDay)
        try store.createRoutine(pushPull)

        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now
        try store.createSession(SessionData(
            routineID: legDay.id,
            routineName: legDay.name,
            startedAt: threeDaysAgo,
            endedAt: threeDaysAgo.addingTimeInterval(45 * 60),
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: squatID, order: 0)]
        ))

        // m2-03: a seeded ExerciseLastPerformance digest for Back Squat, so
        // BurlyWatchUITests can assert the §2 ghost row / prefill ladder
        // against known numbers, set index by set index. Bench Press and
        // Pull-Up deliberately get NO digest -- §2 acceptance #5's other
        // half ("absent digest renders empty ghosts, no crash, no stale
        // data") needs an exercise that has never had one.
        try store.applyDigest(
            lastPerformance: [
                ExerciseLastPerformanceData(
                    exerciseID: squatID,
                    performedAt: threeDaysAgo,
                    sets: [
                        SetSnapshot(weight: Weight(kg: 100), reps: 8),
                        SetSnapshot(weight: Weight(kg: 102.5), reps: 7),
                        SetSnapshot(weight: Weight(kg: 105), reps: 6)
                    ]
                )
            ],
            ackedSessionIDs: []
        )
    }

    /// m2-03 review finding 1 (blocker): leaves Push/Pull `.active` and
    /// in flight, exactly the state a killed/backgrounded-mid-workout watch
    /// would leave behind, so a UI test can attempt a *second* Start (on
    /// Leg Day) and assert it lands on `SessionConflictView` -- never an
    /// unsaved logging screen -- and that Finish/Discard there resolve the
    /// conflict and let the originally-requested Start through.
    private static func seedActiveConflict(into store: SwiftDataStore) throws {
        guard let pushPull = try store.routines(includingArchived: false)
            .first(where: { $0.name == "Push/Pull" })
        else {
            throw SeedError.catalogMissingExercise(name: "Push/Pull")
        }
        let active = SessionBuilder.session(from: pushPull, clock: SystemWallClock())
        try store.saveActiveSession(active)
    }
}

/// Wraps a real `SwiftDataStore` and deterministically fails a chosen
/// method for a chosen number of calls, so BurlyWatchUITests can exercise
/// m2-03 review findings 6-9's save-failure recovery paths -- a lifter
/// mid-workout must never be lied to about whether their sets are saved,
/// and that is very hard to prove from a UI test against a real storage
/// layer, which essentially never fails on the simulator. DEBUG-only, like
/// the rest of this file; every method not named by `fault` forwards to
/// `wrapped` untouched.
@MainActor
final class FaultInjectingStore: BurlyStore {
    enum Fault: String {
        case saveActiveSession
        case createExercise
        case deleteSession
    }

    struct InjectedFailure: Error, Equatable, CustomStringConvertible {
        let fault: Fault
        var description: String { "Injected failure for testing: \(fault.rawValue)" }
    }

    private let wrapped: SwiftDataStore
    private let fault: Fault
    private var successesBeforeFailing: Int
    private var failuresToProduce: Int

    init(
        wrapping store: SwiftDataStore,
        fault: Fault,
        successesBeforeFailing: Int,
        failuresToProduce: Int
    ) {
        self.wrapped = store
        self.fault = fault
        self.successesBeforeFailing = successesBeforeFailing
        self.failuresToProduce = failuresToProduce
    }

    /// Call this first from every method named by a `Fault` case. Throws
    /// once `successesBeforeFailing` calls to *that* method have gone by,
    /// for up to `failuresToProduce` calls -- then reverts to forwarding,
    /// so a UI test's Retry can prove recovery.
    private func maybeFail(_ which: Fault) throws {
        guard which == fault else { return }
        guard successesBeforeFailing <= 0 else {
            successesBeforeFailing -= 1
            return
        }
        guard failuresToProduce > 0 else { return }
        failuresToProduce -= 1
        throw InjectedFailure(fault: which)
    }

    // MARK: - Exercises

    func createExercise(_ exercise: ExerciseData) throws {
        try maybeFail(.createExercise)
        try wrapped.createExercise(exercise)
    }
    func exercise(id: UUID) throws -> ExerciseData? { try wrapped.exercise(id: id) }
    func exercises(includingArchived: Bool) throws -> [ExerciseData] {
        try wrapped.exercises(includingArchived: includingArchived)
    }
    func archiveExercise(id: UUID, at date: Date) throws { try wrapped.archiveExercise(id: id, at: date) }

    // MARK: - Routines

    func createRoutine(_ routine: RoutineData) throws { try wrapped.createRoutine(routine) }
    func routine(id: UUID) throws -> RoutineData? { try wrapped.routine(id: id) }
    func routines(includingArchived: Bool) throws -> [RoutineData] {
        try wrapped.routines(includingArchived: includingArchived)
    }
    func archiveRoutine(id: UUID, at date: Date) throws { try wrapped.archiveRoutine(id: id, at: date) }
    func deleteRoutine(id: UUID) throws { try wrapped.deleteRoutine(id: id) }
    func updateRoutine(_ routine: RoutineData) throws { try wrapped.updateRoutine(routine) }
    func applyRoutineSnapshot(_ routine: RoutineData) throws { try wrapped.applyRoutineSnapshot(routine) }
    func hasRoutines() throws -> Bool { try wrapped.hasRoutines() }
    @discardableResult
    func applyReplicatedSession(_ session: SessionData) throws -> Int {
        try wrapped.applyReplicatedSession(session)
    }
    @discardableResult
    func applyReplicatedSession(_ session: SessionData, upsertingPlaceholderExercises placeholders: [ExerciseData]) throws -> Int {
        try wrapped.applyReplicatedSession(session, upsertingPlaceholderExercises: placeholders)
    }
    func allLoggedSetSlices() throws -> [SetRecordSlice] { try wrapped.allLoggedSetSlices() }

    // MARK: - Sessions

    func createSession(_ session: SessionData) throws { try wrapped.createSession(session) }
    func session(id: UUID) throws -> SessionData? { try wrapped.session(id: id) }
    func sessions() throws -> [SessionData] { try wrapped.sessions() }
    func sessions(state: SessionState) throws -> [SessionData] { try wrapped.sessions(state: state) }
    func loggedSessionCount() throws -> Int { try wrapped.loggedSessionCount() }
    @discardableResult
    func deleteSession(id: UUID) throws -> UUID? {
        try maybeFail(.deleteSession)
        return try wrapped.deleteSession(id: id)
    }

    // MARK: - Active session

    func saveActiveSession(_ active: ActiveSession) throws {
        try maybeFail(.saveActiveSession)
        try wrapped.saveActiveSession(active)
    }
    func activeSession(id: UUID) throws -> ActiveSession? { try wrapped.activeSession(id: id) }
    func resumableActiveSession() throws -> ActiveSession? { try wrapped.resumableActiveSession() }
    @discardableResult
    func applyPhoneEdit(_ session: SessionData) throws -> Int { try wrapped.applyPhoneEdit(session) }

    // MARK: - Digests

    func lastPerformance(exerciseID: UUID) throws -> ExerciseLastPerformanceData? {
        try wrapped.lastPerformance(exerciseID: exerciseID)
    }
    func applyDigest(lastPerformance: [ExerciseLastPerformanceData], ackedSessionIDs: [UUID]) throws {
        try wrapped.applyDigest(lastPerformance: lastPerformance, ackedSessionIDs: ackedSessionIDs)
    }

    // MARK: - Watch working set

    func loggedSessionsAwaitingAck() throws -> [SessionData] { try wrapped.loggedSessionsAwaitingAck() }

    // MARK: - Stats

    func loggedSetSlices(exerciseID: UUID, since: Date?, through: Date?) throws -> [SetRecordSlice] {
        try wrapped.loggedSetSlices(exerciseID: exerciseID, since: since, through: through)
    }
    func loggedSetSlices(window: TrailingWindow, through asOf: Date, calendar: Calendar) throws -> [SetRecordSlice] {
        try wrapped.loggedSetSlices(window: window, through: asOf, calendar: calendar)
    }
    func loggedSessionDates(since: Date, through: Date?) throws -> [Date] {
        try wrapped.loggedSessionDates(since: since, through: through)
    }
    func allLoggedSessionDates() throws -> [Date] { try wrapped.allLoggedSessionDates() }
}
#endif
