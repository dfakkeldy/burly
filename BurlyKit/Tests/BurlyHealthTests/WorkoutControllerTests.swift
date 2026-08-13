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
        await waitUntil { harness.log == [.stopActivity(endedAt)] }

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
        await waitUntil { harness.log == [.stopActivity(endedAt)] }
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

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
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
        factoryFailure: WorkoutHealthError? = nil
    ) {
        let log = CallLog()
        let session = FakeWorkoutSession(log: log)
        let builder = FakeWorkoutBuilder(log: log)
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

    init(log: CallLog) {
        self.log = log
    }

    func beginCollection(at date: Date) async throws {
        log.calls.append(.beginCollection(date))
    }

    func endCollection(at date: Date) async throws {
        log.calls.append(.endCollection(date))
    }

    func finishWorkout(metadata: WorkoutMetadata) async throws {
        log.calls.append(.finishWorkout(metadata))
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
