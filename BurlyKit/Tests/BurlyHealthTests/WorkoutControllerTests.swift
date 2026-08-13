// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BurlyHealth

@Suite("BurlyHealth.WorkoutController")
@MainActor
struct WorkoutControllerTests {
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let endedAt = Date(timeIntervalSince1970: 1_700_003_600)

    @Test("start creates and begins the required indoor strength workout")
    func startUsesRequiredConfiguration() async throws {
        let harness = Harness()

        try await harness.controller.start(at: startedAt)

        #expect(harness.log == [
            .makeSession(.init(activity: .traditionalStrengthTraining, location: .indoor)),
            .startActivity(startedAt),
            .beginCollection(startedAt)
        ])
        #expect(harness.controller.lifecycle == .active)
    }

    @Test("finish waits for stopped, then performs the exact persistence sequence")
    func finishWaitsForStoppedAndPreservesExactOrder() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let finish = Task { @MainActor in
            try await harness.controller.finish(
                at: endedAt,
                metadata: ["externalUUID": "workout-123"]
            )
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }

        // Pin the asynchronous dependency independently: none of the builder
        // calls is legal merely because stopActivity returned.
        #expect(harness.log == [.stopActivity(endedAt)])
        harness.session.emit(.stopped)
        try await finish.value

        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .finishWorkout(["externalUUID": "workout-123"]),
            .endSession
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("discard waits for stopped, discards, and never finishes a workout")
    func discardNeverPersistsWorkout() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let discard = Task { @MainActor in
            try await harness.controller.discard(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }

        // As with finish, collection must still be untouched while discard is
        // waiting for the session's stopped state.
        #expect(harness.log == [.stopActivity(endedAt)])
        harness.session.emit(.stopped)
        try await discard.value

        // The whole log is intentional: adding finishWorkout anywhere in this
        // path must fail this assertion.
        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .discardWorkout,
            .endSession
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("a missing stopped callback times out without ending collection")
    func stoppedStateTimeoutDoesNotProceedOutOfOrder() async throws {
        let timeout = ImmediateStopTimeout()
        let harness = Harness(timeout: timeout)
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        await #expect(throws: WorkoutControllerError.stoppedStateTimedOut) {
            try await harness.controller.finish(at: endedAt)
        }

        #expect(harness.log == [.stopActivity(endedAt)])
        #expect(harness.controller.lifecycle == .active)
    }

    @Test("retry after a stopped-state timeout re-issues stop activity")
    func retryAfterStopTimeoutReissuesStopActivity() async throws {
        let timeout = ImmediateStopTimeout()
        let harness = Harness(timeout: timeout)
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        await #expect(throws: WorkoutControllerError.stoppedStateTimedOut) {
            try await harness.controller.finish(at: endedAt)
        }
        #expect(harness.log == [.stopActivity(endedAt)])

        await #expect(throws: WorkoutControllerError.stoppedStateTimedOut) {
            try await harness.controller.finish(at: endedAt)
        }

        let stopCount = harness.log.calls.filter {
            if case .stopActivity = $0 { true } else { false }
        }.count
        #expect(stopCount == 2)
    }

    @Test("a controller rejects a second live workout while one is active")
    func onlyOneLiveWorkoutCanBeActive() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        let firstStartLog = harness.log.calls

        await #expect(throws: WorkoutControllerError.workoutAlreadyActive) {
            try await harness.controller.start(at: startedAt.addingTimeInterval(1))
        }

        #expect(harness.log == firstStartLog)
    }

    @Test("HealthKit's another-session error remains distinguishable")
    func anotherWorkoutSessionStartedIsDistinguishable() async {
        let harness = Harness(factoryFailure: .anotherWorkoutSessionStarted)

        await #expect(throws: WorkoutControllerError.anotherWorkoutSessionStarted) {
            try await harness.controller.start(at: startedAt)
        }
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("begin-collection failure releases finish before stop activity is issued")
    func beginCollectionFailureReleasesFinishWithoutStopping() async throws {
        let beginCollection = OperationGate()
        let failure = WorkoutHealthError.operationFailed("begin collection failed")
        let harness = Harness(beginCollectionGate: beginCollection)

        let start = Task { @MainActor in
            try await harness.controller.start(at: startedAt)
        }
        try await waitUntil { harness.log.calls.contains(.beginCollection(startedAt)) }

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(!harness.log.calls.contains(.stopActivity(endedAt)))

        beginCollection.fail(with: failure)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await start.value
        }

        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await finish.value
        }
        #expect(harness.controller.lifecycle == .idle)

        try await harness.controller.start(at: startedAt.addingTimeInterval(120))
        let secondFinish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt.addingTimeInterval(120))
        }
        try await waitUntil {
            harness.log.calls.contains(.stopActivity(endedAt.addingTimeInterval(120)))
        }
        harness.session.emit(.stopped)
        try await secondFinish.value
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("finish waits for collection startup before issuing stop activity")
    func finishWaitsForCollectionStartupBeforeStopping() async throws {
        let beginCollection = OperationGate()
        let harness = Harness(beginCollectionGate: beginCollection)

        let start = Task { @MainActor in
            try await harness.controller.start(at: startedAt)
        }
        try await waitUntil { harness.log.calls.contains(.beginCollection(startedAt)) }

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(!harness.log.calls.contains(.stopActivity(endedAt)))

        beginCollection.succeedAll()
        try await start.value
        try await waitUntil { harness.log.calls.contains(.stopActivity(endedAt)) }
        harness.session.emit(.stopped)
        try await finish.value

        let beginIndex = try #require(
            harness.log.calls.firstIndex(of: .beginCollection(startedAt))
        )
        let stopIndex = try #require(
            harness.log.calls.firstIndex(of: .stopActivity(endedAt))
        )
        #expect(beginIndex < stopIndex)
    }

    @Test("finish retry resumes after collection already ended")
    func finishRetryDoesNotEndCollectionTwice() async throws {
        let failure = WorkoutHealthError.operationFailed("finish failed")
        let harness = Harness(finishFailures: [failure])
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let firstFinish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        harness.session.emit(.stopped)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await firstFinish.value
        }

        let retryDate = endedAt.addingTimeInterval(30)
        try await harness.controller.finish(at: retryDate)

        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .finishWorkout([:]),
            .endSession,
            .finishWorkout([:])
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("discard remains an escape hatch after collection ended")
    func discardAfterFinishFailureDoesNotEndCollectionTwice() async throws {
        let failure = WorkoutHealthError.operationFailed("finish failed")
        let harness = Harness(finishFailures: [failure])
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        harness.session.emit(.stopped)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await finish.value
        }

        let retryDate = endedAt.addingTimeInterval(30)
        let retry = Task { @MainActor in
            try await harness.controller.discard(at: retryDate)
        }
        try await waitUntil {
            harness.log.calls.last == .stopActivity(retryDate)
                || harness.log.calls.last == .endSession
        }
        if harness.log.calls.last == .stopActivity(retryDate) {
            harness.session.emit(.stopped)
        }
        try await retry.value

        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .finishWorkout([:]),
            .endSession,
            .discardWorkout
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("retry after end-collection failure keeps the original end date and does not stop twice")
    func endCollectionRetryUsesOriginalEndDate() async throws {
        let failure = WorkoutHealthError.operationFailed("end collection failed")
        let harness = Harness(endCollectionFailures: [failure])
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let firstFinish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        harness.session.emit(.stopped)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await firstFinish.value
        }

        let retryDate = endedAt.addingTimeInterval(30)
        let retry = Task { @MainActor in
            try await harness.controller.finish(at: retryDate)
        }
        try await waitUntil {
            harness.log.calls.last == .stopActivity(retryDate)
                || harness.log.calls.last == .endSession
        }
        if harness.log.calls.last == .stopActivity(retryDate) {
            harness.session.emit(.stopped)
        }
        try await retry.value

        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .endCollection(endedAt),
            .finishWorkout([:]),
            .endSession
        ])
    }

    @Test("discard retry after end-collection failure keeps the original end date")
    func discardRetriesEndCollectionWithoutStoppingTwice() async throws {
        let failure = WorkoutHealthError.operationFailed("end collection failed")
        let harness = Harness(endCollectionFailures: [failure])
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let firstDiscard = Task { @MainActor in
            try await harness.controller.discard(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        harness.session.emit(.stopped)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await firstDiscard.value
        }

        let retryDate = endedAt.addingTimeInterval(30)
        let retry = Task { @MainActor in
            try await harness.controller.discard(at: retryDate)
        }
        try await waitUntil {
            harness.log.calls.last == .stopActivity(retryDate)
                || harness.log.calls.last == .endSession
        }
        if harness.log.calls.last == .stopActivity(retryDate) {
            harness.session.emit(.stopped)
        }
        try await retry.value

        #expect(harness.log == [
            .stopActivity(endedAt),
            .delegateState(.stopped),
            .endCollection(endedAt),
            .endCollection(endedAt),
            .discardWorkout,
            .endSession
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("ending lifecycle rejects a second termination while waiting for stopped")
    func endingLifecycleRejectsSecondTerminationWhileWaitingForStopped() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let firstFinish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }

        await #expect(throws: WorkoutControllerError.terminationAlreadyInProgress) {
            try await harness.controller.discard(at: endedAt)
        }
        #expect(harness.log == [.stopActivity(endedAt)])

        harness.session.emit(.stopped)
        try await firstFinish.value
    }

    @Test("session failure during termination does not admit a second termination")
    func sessionFailureDuringTerminationPreservesEndingLifecycle() async throws {
        let failure = WorkoutHealthError.operationFailed("session failed")
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }

        harness.session.emit(.failed(failure))
        await #expect(throws: WorkoutControllerError.terminationAlreadyInProgress) {
            try await harness.controller.discard(at: endedAt)
        }
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await finish.value
        }
    }

    @Test("a second termination is rejected while end collection is suspended")
    func endingLifecycleRejectsASecondTermination() async throws {
        let endCollection = OperationGate()
        let harness = Harness(endCollectionGate: endCollection)
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let firstFinish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        harness.session.emit(.stopped)
        try await waitUntil { harness.log.calls.contains(.endCollection(endedAt)) }

        let secondTermination = Task { @MainActor in
            try await harness.controller.discard(at: endedAt)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        let endCollectionCount = harness.log.calls.filter { $0 == .endCollection(endedAt) }.count
        endCollection.succeedAll()
        await #expect(throws: WorkoutControllerError.terminationAlreadyInProgress) {
            try await secondTermination.value
        }
        #expect(endCollectionCount == 1)
        try await firstFinish.value
    }

    @Test("completed workout detaches its old session delegate")
    func completedWorkoutIgnoresLateSessionFailure() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log.calls.contains(.stopActivity(endedAt)) }
        harness.session.emit(.stopped)
        try await finish.value

        harness.session.emit(.failed(.operationFailed("late failure")))

        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("finish cancellation releases the stopped wait")
    func cancellingFinishThrowsCancellation() async throws {
        let timeout = ManualStopTimeout()
        let harness = Harness(timeout: timeout)
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log == [.stopActivity(endedAt)] }
        finish.cancel()
        await timeout.fireNextWhenReady()

        await #expect(throws: CancellationError.self) {
            try await finish.value
        }
        #expect(harness.controller.lifecycle == .active)
    }

    @Test("finish and discard report no active workout while idle")
    func idleTerminationReportsNoActiveWorkout() async {
        let harness = Harness()

        await #expect(throws: WorkoutControllerError.noActiveWorkout) {
            try await harness.controller.finish(at: endedAt)
        }
        await #expect(throws: WorkoutControllerError.noActiveWorkout) {
            try await harness.controller.discard(at: endedAt)
        }
    }

    @Test("a failed session becomes observable and discard remains reachable")
    func failedSessionCanBeDiscardedWithoutWaitingForStopped() async throws {
        let timeout = ManualStopTimeout()
        let harness = Harness(timeout: timeout)
        try await harness.controller.start(at: startedAt)
        harness.log.removeAll()

        harness.session.emit(.failed(.anotherWorkoutSessionStarted))
        #expect(harness.controller.lifecycle == .failed(.anotherWorkoutSessionStarted))

        let discard = Task { @MainActor in
            try await harness.controller.discard(at: endedAt)
        }
        try await waitUntil {
            harness.log.calls.last == .stopActivity(endedAt)
                || harness.log.calls.last == .endSession
        }
        if harness.log.calls.last == .stopActivity(endedAt) {
            await timeout.fireNextWhenReady()
        }
        try await discard.value

        #expect(harness.log == [
            .delegateState(.failed(.anotherWorkoutSessionStarted)),
            .endCollection(endedAt),
            .discardWorkout,
            .endSession
        ])
        #expect(harness.controller.lifecycle == .idle)
    }

    @Test("starting after a session failure reports that failure")
    func startAfterSessionFailureReportsFailure() async throws {
        let harness = Harness()
        try await harness.controller.start(at: startedAt)
        harness.session.emit(.failed(.anotherWorkoutSessionStarted))
        let logBeforeRetry = harness.log.calls

        await #expect(throws: WorkoutControllerError.anotherWorkoutSessionStarted) {
            try await harness.controller.start(at: startedAt.addingTimeInterval(1))
        }

        #expect(harness.log.calls == logBeforeRetry)
    }

    @Test("the public default stopped-state policy waits five seconds")
    func publicDefaultStopTimeoutUsesFiveSeconds() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        try await FiveSecondWorkoutStopTimeout().wait()

        #expect(clock.now - start >= .seconds(5))
    }

    @Test("stopped callback cancels timeout even when end collection fails")
    func stoppedCallbackCancelsTimeoutBeforeEndCollectionFailure() async throws {
        let timeout = CancellationRecordingTimeout()
        let failure = WorkoutHealthError.operationFailed("end collection failed")
        let harness = Harness(timeout: timeout, endCollectionFailures: [failure])
        try await harness.controller.start(at: startedAt)

        let finish = Task { @MainActor in
            try await harness.controller.finish(at: endedAt)
        }
        try await waitUntil { harness.log.calls.contains(.stopActivity(endedAt)) }
        harness.session.emit(.stopped)
        await #expect(throws: WorkoutControllerError.healthOperationFailed(failure)) {
            try await finish.value
        }

        let observedCancellation = await eventually {
            await timeout.cancellationObserved
        }
        await timeout.release()
        #expect(observedCancellation)
        #expect(harness.controller.lifecycle == .active)
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
        try #require(condition(), "Asynchronous condition was not reached", sourceLocation: sourceLocation)
    }
}

@MainActor
private final class Harness {
    let log: CallLog
    let session: FakeWorkoutSession
    let builder: FakeWorkoutBuilder
    let controller: WorkoutController

    init(
        timeout: any WorkoutStopTimeout = NeverStopTimeout(),
        factoryFailure: WorkoutHealthError? = nil,
        beginCollectionGate: OperationGate? = nil,
        endCollectionGate: OperationGate? = nil,
        endCollectionFailures: [WorkoutHealthError] = [],
        finishFailures: [WorkoutHealthError] = []
    ) {
        let log = CallLog()
        let session = FakeWorkoutSession(log: log)
        let builder = FakeWorkoutBuilder(
            log: log,
            beginCollectionGate: beginCollectionGate,
            endCollectionGate: endCollectionGate,
            endCollectionFailures: endCollectionFailures,
            finishFailures: finishFailures
        )
        let factory = FakeWorkoutFactory(
            log: log,
            resources: .init(session: session, builder: builder),
            failure: factoryFailure
        )
        self.log = log
        self.session = session
        self.builder = builder
        controller = WorkoutController(factory: factory, stopTimeout: timeout)
    }
}

@MainActor
private final class CallLog {
    var calls: [WorkoutCall] = []

    func removeAll() {
        calls.removeAll()
    }

    static func == (lhs: CallLog, rhs: [WorkoutCall]) -> Bool {
        lhs.calls == rhs
    }
}

private enum WorkoutCall: Equatable {
    case makeSession(WorkoutConfiguration)
    case startActivity(Date)
    case beginCollection(Date)
    case stopActivity(Date)
    case delegateState(WorkoutSessionState)
    case endCollection(Date)
    case finishWorkout(WorkoutMetadata)
    case discardWorkout
    case endSession
}

@MainActor
private final class FakeWorkoutFactory: WorkoutSessionCreating {
    private let log: CallLog
    private let resources: LiveWorkoutResources
    private let failure: WorkoutHealthError?

    init(log: CallLog, resources: LiveWorkoutResources, failure: WorkoutHealthError?) {
        self.log = log
        self.resources = resources
        self.failure = failure
    }

    func makeLiveWorkout(configuration: WorkoutConfiguration) throws -> LiveWorkoutResources {
        log.calls.append(.makeSession(configuration))
        if let failure { throw failure }
        return resources
    }
}

@MainActor
private final class FakeWorkoutSession: WorkoutSessionProtocol {
    var stateHandler: (@MainActor @Sendable (WorkoutSessionState) -> Void)?
    private let log: CallLog

    init(log: CallLog) {
        self.log = log
    }

    func startActivity(at date: Date) {
        log.calls.append(.startActivity(date))
    }

    func stopActivity(at date: Date) {
        log.calls.append(.stopActivity(date))
    }

    func end() {
        log.calls.append(.endSession)
    }

    func emit(_ state: WorkoutSessionState) {
        log.calls.append(.delegateState(state))
        stateHandler?(state)
    }
}

@MainActor
private final class FakeWorkoutBuilder: LiveWorkoutBuilding {
    private let log: CallLog
    private let beginCollectionGate: OperationGate?
    private let endCollectionGate: OperationGate?
    private var endCollectionFailures: [WorkoutHealthError]
    private var finishFailures: [WorkoutHealthError]

    init(
        log: CallLog,
        beginCollectionGate: OperationGate? = nil,
        endCollectionGate: OperationGate? = nil,
        endCollectionFailures: [WorkoutHealthError] = [],
        finishFailures: [WorkoutHealthError] = []
    ) {
        self.log = log
        self.beginCollectionGate = beginCollectionGate
        self.endCollectionGate = endCollectionGate
        self.endCollectionFailures = endCollectionFailures
        self.finishFailures = finishFailures
    }

    func beginCollection(at date: Date) async throws {
        log.calls.append(.beginCollection(date))
        try await beginCollectionGate?.wait()
    }

    func endCollection(at date: Date) async throws {
        log.calls.append(.endCollection(date))
        try await endCollectionGate?.wait()
        if !endCollectionFailures.isEmpty {
            throw endCollectionFailures.removeFirst()
        }
    }

    func finishWorkout(metadata: WorkoutMetadata) async throws {
        log.calls.append(.finishWorkout(metadata))
        if !finishFailures.isEmpty {
            throw finishFailures.removeFirst()
        }
    }

    func discardWorkout() {
        log.calls.append(.discardWorkout)
    }
}

private struct NeverStopTimeout: WorkoutStopTimeout {
    func wait() async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private struct ImmediateStopTimeout: WorkoutStopTimeout {
    func wait() async throws {}
}

@MainActor
private final class OperationGate {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private var isOpen = false

    func wait() async throws {
        if isOpen { return }
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func fail(with error: any Error) {
        guard !continuations.isEmpty else { return }
        isOpen = true
        continuations.removeFirst().resume(throwing: error)
    }

    func succeedAll() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ManualStopTimeout: WorkoutStopTimeout {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        try Task.checkCancellation()
    }

    func fireNextWhenReady() async {
        while continuations.isEmpty {
            await Task.yield()
        }
        continuations.removeFirst().resume()
    }
}

private actor CancellationRecordingTimeout: WorkoutStopTimeout {
    private(set) var cancellationObserved = false
    private var released = false

    func wait() async throws {
        while !Task.isCancelled && !released {
            await Task.yield()
        }
        if Task.isCancelled {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func release() {
        released = true
    }
}
