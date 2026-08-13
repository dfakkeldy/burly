// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Owns the one-live-workout invariant and the sole ordered termination path.
///
/// Main-actor isolation is part of the seam: clients, fakes, and the HealthKit
/// adapter all enter through one executor even though HealthKit delegates may
/// originate on arbitrary queues.
@MainActor
public final class WorkoutController {
    public private(set) var lifecycle: WorkoutLifecycle = .idle

    private let factory: any WorkoutSessionCreating
    private let stopTimeout: any WorkoutStopTimeout
    private var resources: LiveWorkoutResources?
    private var observedSessionState: WorkoutSessionState = .notStarted
    private var stoppedWaiter: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(
        factory: any WorkoutSessionCreating,
        stopTimeout: any WorkoutStopTimeout = FiveSecondWorkoutStopTimeout()
    ) {
        self.factory = factory
        self.stopTimeout = stopTimeout
    }

    public func start(at date: Date) async throws {
        guard lifecycle == .idle else {
            throw WorkoutControllerError.workoutAlreadyActive
        }

        let resources: LiveWorkoutResources
        do {
            resources = try factory.makeLiveWorkout(configuration: .init(
                activity: .traditionalStrengthTraining,
                location: .indoor
            ))
        } catch let error as WorkoutHealthError {
            if error == .anotherWorkoutSessionStarted {
                throw WorkoutControllerError.anotherWorkoutSessionStarted
            }
            throw WorkoutControllerError.healthOperationFailed(error)
        } catch {
            throw WorkoutControllerError.healthOperationFailed(.operationFailed(String(describing: error)))
        }

        self.resources = resources
        observedSessionState = .notStarted
        resources.session.stateHandler = { [weak self] state in
            self?.receive(state)
        }
        lifecycle = .active
        resources.session.startActivity(at: date)

        do {
            try await resources.builder.beginCollection(at: date)
        } catch {
            resources.session.stateHandler = nil
            resources.session.end()
            self.resources = nil
            lifecycle = .idle
            throw mapHealthError(error)
        }
    }

    public func finish(at date: Date, metadata: WorkoutMetadata = [:]) async throws {
        let resources = try beginTermination()
        do {
            try await stopActivityIfNeeded(resources.session, at: date)
            try await resources.builder.endCollection(at: date)
            try await resources.builder.finishWorkout(metadata: metadata)
            resources.session.end()
            clearCompletedWorkout(resources.session)
        } catch {
            lifecycle = .active
            throw mapHealthError(error)
        }
    }

    public func discard(at date: Date) async throws {
        let resources = try beginTermination()
        do {
            try await stopActivityIfNeeded(resources.session, at: date)
            try await resources.builder.endCollection(at: date)
            resources.builder.discardWorkout()
            resources.session.end()
            clearCompletedWorkout(resources.session)
        } catch {
            lifecycle = .active
            throw mapHealthError(error)
        }
    }

    private func beginTermination() throws -> LiveWorkoutResources {
        switch lifecycle {
        case .idle:
            throw WorkoutControllerError.noActiveWorkout
        case .ending:
            throw WorkoutControllerError.terminationAlreadyInProgress
        case .active:
            break
        }
        guard let resources else {
            throw WorkoutControllerError.noActiveWorkout
        }
        lifecycle = .ending
        return resources
    }

    private func stopActivityIfNeeded(
        _ session: any WorkoutSessionProtocol,
        at date: Date
    ) async throws {
        guard observedSessionState != .stopped else { return }

        // Never proceed out of order when HealthKit loses a delegate callback.
        // Five seconds is short enough for a watch interaction, while timeout
        // leaves the workout active so the caller can retry after a late state.
        try await withCheckedThrowingContinuation { continuation in
            stoppedWaiter = continuation
            timeoutTask = Task { [weak self, stopTimeout] in
                do {
                    try await stopTimeout.wait()
                } catch {
                    return
                }
                self?.stoppedStateTimedOut()
            }
            session.stopActivity(at: date)
        }
    }

    private func receive(_ state: WorkoutSessionState) {
        observedSessionState = state
        switch state {
        case .stopped:
            resumeStoppedWaiter()
        case let .failed(error):
            resumeStoppedWaiter(throwing: WorkoutControllerError.healthOperationFailed(error))
        case .notStarted, .prepared, .running, .paused, .ended:
            break
        }
    }

    private func stoppedStateTimedOut() {
        resumeStoppedWaiter(throwing: WorkoutControllerError.stoppedStateTimedOut)
    }

    private func resumeStoppedWaiter(throwing error: (any Error)? = nil) {
        guard let stoppedWaiter else { return }
        self.stoppedWaiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let error {
            stoppedWaiter.resume(throwing: error)
        } else {
            stoppedWaiter.resume()
        }
    }

    private func clearCompletedWorkout(_ session: any WorkoutSessionProtocol) {
        session.stateHandler = nil
        resources = nil
        observedSessionState = .notStarted
        lifecycle = .idle
    }

    private func mapHealthError(_ error: any Error) -> WorkoutControllerError {
        if let controllerError = error as? WorkoutControllerError {
            return controllerError
        }
        if let healthError = error as? WorkoutHealthError {
            if healthError == .anotherWorkoutSessionStarted {
                return .anotherWorkoutSessionStarted
            }
            return .healthOperationFailed(healthError)
        }
        return .healthOperationFailed(.operationFailed(String(describing: error)))
    }
}
