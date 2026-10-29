// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §4 at the session level: authorization at first session start,
// degraded mode, linking metadata, the recovery matrix and the
// duration-only workout. The end-sequence order itself is pinned by
// WorkoutControllerTests; these tests pin which sessions get a workout.
import Foundation
import Testing
@testable import BurlyHealth

@Suite("BurlyHealth.SessionWorkoutRecorder")
@MainActor
struct SessionWorkoutRecorderTests {
    private let sessionID = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000001")!
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let endedAt = Date(timeIntervalSince1970: 1_700_003_600)

    @Test("first session start asks once, then a finished session saves one linked live workout")
    func grantedSessionSavesLinkedLiveWorkout() async {
        let rig = Rig(status: .notDetermined, grant: .authorized)

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(rig.store.authorizationRequests == 1)
        #expect(recording == .live(workoutID: rig.builder.savedWorkoutID))
        #expect(rig.log.calls == [
            .startActivity(startedAt),
            .beginCollection(startedAt),
            .stopActivity(endedAt),
            .endCollection(endedAt),
            .finishWorkout([
                "HKExternalUUID": sessionID.uuidString,
                "HKWorkoutBrandName": "Burly"
            ]),
            .endSession
        ])
        #expect(rig.store.durationOnlySaves.isEmpty)
        #expect(rig.recorder.liveSessionID == nil)
    }

    @Test("declined authorization starts nothing, saves nothing and never asks again")
    func declinedAuthorizationDegradesQuietly() async {
        let rig = Rig(status: .notDetermined, grant: .denied)

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )
        await rig.recorder.sessionDidStart(sessionID: UUID(), at: endedAt).value

        #expect(recording == .notSaved)
        #expect(rig.store.authorizationRequests == 1)
        #expect(rig.log.calls.isEmpty)
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("unavailable Health starts nothing and never prompts")
    func unavailableHealthNeverPrompts() async {
        let rig = Rig(status: .unavailable)

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .notSaved)
        #expect(rig.store.authorizationRequests == 0)
        #expect(rig.log.calls.isEmpty)
    }

    @Test("discard ends the live workout without ever finishing it")
    func discardNeverSavesWorkout() async {
        let rig = Rig(status: .authorized)

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        await rig.recorder.sessionDidDiscard(sessionID: sessionID).value

        #expect(rig.log.calls.contains(.discardWorkout))
        #expect(!rig.log.calls.contains { if case .finishWorkout = $0 { true } else { false } })
        #expect(rig.store.durationOnlySaves.isEmpty)
        #expect(rig.recorder.liveSessionID == nil)
    }

    @Test("finish waits for a start that is still on the authorization prompt")
    func finishIsOrderedAfterPendingStart() async {
        let gate = Gate()
        let rig = Rig(status: .notDetermined, grant: .authorized, authorizationGate: gate)

        rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt)
        let finish = Task { @MainActor in
            await rig.recorder.sessionDidFinish(sessionID: sessionID, startedAt: startedAt, endedAt: endedAt)
        }
        await Task.yield()
        gate.open()

        #expect(await finish.value == .live(workoutID: rig.builder.savedWorkoutID))
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("row 2: no live workout on finish saves one duration-only workout with the same metadata")
    func missingLiveWorkoutSavesDurationOnly() async {
        let rig = Rig(status: .authorized)

        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .retrospective(workoutID: rig.store.savedWorkoutID))
        #expect(recording.lacksSensorData)
        #expect(rig.store.durationOnlySaves == [
            .init(start: startedAt, end: endedAt, metadata: .linking(sessionID: sessionID))
        ])
        #expect(rig.log.calls.isEmpty)
    }

    @Test("a workout already linked to the session is never saved twice")
    func linkedWorkoutIsNotDuplicated() async {
        let rig = Rig(status: .authorized)
        rig.store.linkedCounts[sessionID] = 1

        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .alreadySaved)
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("an unanswerable linked-workout query saves nothing rather than risk a duplicate")
    func failedLinkQuerySavesNothing() async {
        let rig = Rig(status: .authorized)
        rig.store.countFailure = .operationFailed("query")

        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .notSaved)
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("a live start that fails falls back to the duration-only workout on finish")
    func failedLiveStartFallsBack() async {
        let rig = Rig(status: .authorized, factoryFailure: .operationFailed("no sensors"))

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(rig.recorder.liveSessionID == nil)
        #expect(recording == .retrospective(workoutID: rig.store.savedWorkoutID))
    }

    @Test("a stuck end sequence times out without a second save")
    func stuckFinishTimesOut() async {
        let rig = Rig(status: .authorized, sleep: { _ in await Task.yield() }, finishGate: Gate())

        await rig.recorder.sessionDidStart(sessionID: sessionID, at: startedAt).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .notSaved)
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("row 1: a recovered workout is reattached to the active session and finished in order")
    func recoveredWorkoutIsReattached() async {
        let rig = Rig(status: .authorized)
        rig.store.recoverable = rig.resources

        await rig.recorder.reconcile(activeSessionID: sessionID).value
        let recording = await rig.recorder.sessionDidFinish(
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt
        )

        #expect(recording == .live(workoutID: rig.builder.savedWorkoutID))
        #expect(rig.log.calls == [
            .stopActivity(endedAt),
            .endCollection(endedAt),
            .finishWorkout(.linking(sessionID: sessionID)),
            .endSession
        ])
        #expect(rig.store.durationOnlySaves.isEmpty)
    }

    @Test("row 3: a recovered workout with no active session is ended and discarded quietly")
    func orphanWorkoutIsDiscarded() async {
        let rig = Rig(status: .authorized)
        rig.store.recoverable = rig.resources

        await rig.recorder.reconcile(activeSessionID: nil).value

        #expect(rig.log.calls.contains(.discardWorkout))
        #expect(rig.log.calls.last == .endSession)
        #expect(!rig.log.calls.contains { if case .finishWorkout = $0 { true } else { false } })
        #expect(rig.recorder.liveSessionID == nil)
    }

    @Test("reconcile with nothing to recover leaves the recorder idle")
    func reconcileWithNothingRecoverable() async {
        let rig = Rig(status: .authorized)

        await rig.recorder.reconcile(activeSessionID: sessionID).value

        #expect(rig.recorder.liveSessionID == nil)
        #expect(rig.log.calls.isEmpty)
    }
}

// MARK: - Fakes

@MainActor
private final class Rig {
    let log = Log()
    let store: FakeHealthStore
    let builder: FakeBuilder
    let resources: LiveWorkoutResources
    let recorder: SessionWorkoutRecorder

    init(
        status: WorkoutAuthorizationStatus,
        grant: WorkoutAuthorizationStatus = .authorized,
        authorizationGate: Gate? = nil,
        factoryFailure: WorkoutHealthError? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        },
        finishGate: Gate? = nil
    ) {
        store = FakeHealthStore(status: status, grant: grant, gate: authorizationGate)
        builder = FakeBuilder(log: log, finishGate: finishGate)
        resources = LiveWorkoutResources(session: FakeSession(log: log), builder: builder)
        let factory = FakeFactory(resources: resources, failure: factoryFailure)
        recorder = SessionWorkoutRecorder(
            store: store,
            controller: WorkoutController(factory: factory),
            sleep: sleep,
            now: { Date(timeIntervalSince1970: 1_700_007_200) }
        )
    }
}

@MainActor
private final class Log {
    var calls: [Call] = []
}

private enum Call: Equatable {
    case startActivity(Date)
    case beginCollection(Date)
    case stopActivity(Date)
    case endCollection(Date)
    case finishWorkout(WorkoutMetadata)
    case discardWorkout
    case endSession
}

@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class FakeHealthStore: WorkoutHealthStore {
    struct DurationOnlySave: Equatable {
        let start: Date
        let end: Date
        let metadata: WorkoutMetadata
    }

    private(set) var authorizationStatus: WorkoutAuthorizationStatus
    private let grant: WorkoutAuthorizationStatus
    private let gate: Gate?
    private(set) var authorizationRequests = 0
    var recoverable: LiveWorkoutResources?
    var linkedCounts: [UUID: Int] = [:]
    var countFailure: WorkoutHealthError?
    private(set) var durationOnlySaves: [DurationOnlySave] = []
    let savedWorkoutID = UUID()

    init(status: WorkoutAuthorizationStatus, grant: WorkoutAuthorizationStatus, gate: Gate?) {
        authorizationStatus = status
        self.grant = grant
        self.gate = gate
    }

    func requestAuthorization() async throws {
        authorizationRequests += 1
        await gate?.wait()
        authorizationStatus = grant
    }

    func recoverLiveWorkout() async throws -> LiveWorkoutResources? {
        defer { recoverable = nil }
        return recoverable
    }

    func workoutCount(linkedTo sessionID: UUID) async throws -> Int {
        if let countFailure { throw countFailure }
        return linkedCounts[sessionID, default: 0]
    }

    func saveDurationOnlyWorkout(start: Date, end: Date, metadata: WorkoutMetadata) async throws -> UUID? {
        durationOnlySaves.append(.init(start: start, end: end, metadata: metadata))
        return savedWorkoutID
    }

    func deleteWorkouts(linkedTo sessionID: UUID) async throws -> Int {
        linkedCounts.removeValue(forKey: sessionID) ?? 0
    }
}

@MainActor
private final class FakeFactory: WorkoutSessionCreating {
    private let resources: LiveWorkoutResources
    private let failure: WorkoutHealthError?

    init(resources: LiveWorkoutResources, failure: WorkoutHealthError?) {
        self.resources = resources
        self.failure = failure
    }

    func makeLiveWorkout(configuration _: WorkoutConfiguration) throws -> LiveWorkoutResources {
        if let failure { throw failure }
        return resources
    }
}

/// Reports `.stopped` as soon as activity stops, as HealthKit does.
@MainActor
private final class FakeSession: WorkoutSessionProtocol {
    var stateHandler: (@MainActor @Sendable (WorkoutSessionState) -> Void)?
    private let log: Log

    init(log: Log) {
        self.log = log
    }

    func startActivity(at date: Date) {
        log.calls.append(.startActivity(date))
    }

    func stopActivity(at date: Date) {
        log.calls.append(.stopActivity(date))
        stateHandler?(.stopped)
    }

    func end() {
        log.calls.append(.endSession)
    }
}

@MainActor
private final class FakeBuilder: LiveWorkoutBuilding {
    private let log: Log
    private let finishGate: Gate?
    let savedWorkoutID = UUID()

    init(log: Log, finishGate: Gate?) {
        self.log = log
        self.finishGate = finishGate
    }

    func beginCollection(at date: Date) async throws {
        log.calls.append(.beginCollection(date))
    }

    func endCollection(at date: Date) async throws {
        log.calls.append(.endCollection(date))
    }

    func finishWorkout(metadata: WorkoutMetadata) async throws -> UUID? {
        log.calls.append(.finishWorkout(metadata))
        await finishGate?.wait()
        return savedWorkoutID
    }

    func discardWorkout() {
        log.calls.append(.discardWorkout)
    }
}
