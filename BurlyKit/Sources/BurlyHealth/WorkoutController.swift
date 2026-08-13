// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Owns the one-live-workout invariant and the sole ordered termination path.
///
/// Main-actor isolation is part of the seam: clients, fakes, and the HealthKit
/// adapter all enter through one executor even though HealthKit delegates may
/// originate on arbitrary queues.
@MainActor
public final class WorkoutController {
    /// The controller's availability for commands, not HealthKit's activity state.
    ///
    /// `.idle` owns no workout resources and permits `start`; `.active` owns a
    /// workout with no termination call in flight and means "terminable, retry
    /// me" rather than "currently collecting"; `.ending` has one termination
    /// call in flight and rejects another; `.failed(error)` owns a workout whose
    /// session reported `error`, rejects `start` with that error, and still permits
    /// `finish` or `discard` so the caller can clean it up.
    public private(set) var lifecycle: WorkoutLifecycle = .idle

    private enum CollectionState {
        case notStarted
        case starting
        case collecting
        case failed(WorkoutControllerError)
    }

    private enum TerminationProgress {
        case collecting
        case stopping(Date)
        case stopped(Date)
        case collectionEnded(Date)
        case sessionEnded(Date)

        var endDate: Date? {
            switch self {
            case .collecting: nil
            case let .stopping(date), let .stopped(date), let .collectionEnded(date),
                 let .sessionEnded(date): date
            }
        }
    }

    private struct StoppedWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let factory: any WorkoutSessionCreating
    private let stopTimeout: any WorkoutStopTimeout
    private var resources: LiveWorkoutResources?
    private var collectionState: CollectionState = .notStarted
    private var collectionWaiter: CheckedContinuation<Void, any Error>?
    private var terminationProgress: TerminationProgress?
    private var observedSessionState: WorkoutSessionState = .notStarted
    private var stoppedWaiter: StoppedWaiter?
    private var timeoutTask: Task<Void, Never>?

    public init(
        factory: any WorkoutSessionCreating,
        stopTimeout: any WorkoutStopTimeout = FiveSecondWorkoutStopTimeout()
    ) {
        self.factory = factory
        self.stopTimeout = stopTimeout
    }

    public func start(at date: Date) async throws {
        switch lifecycle {
        case .idle:
            break
        case let .failed(error):
            throw error
        case .active, .ending:
            throw WorkoutControllerError.workoutAlreadyActive
        }

        let resources: LiveWorkoutResources
        do {
            resources = try factory.makeLiveWorkout(configuration: .init(
                activity: .traditionalStrengthTraining,
                location: .indoor
            ))
        } catch {
            throw mapHealthError(error)
        }

        self.resources = resources
        collectionState = .starting
        terminationProgress = .collecting
        observedSessionState = .notStarted
        resources.session.stateHandler = { [weak self] state in
            self?.receive(state)
        }
        lifecycle = .active
        resources.session.startActivity(at: date)

        do {
            try await resources.builder.beginCollection(at: date)
            guard isCurrent(resources) else {
                throw WorkoutControllerError.noActiveWorkout
            }
            collectionState = .collecting
            resumeCollectionWaiter()
        } catch {
            let mappedError = mapHealthError(error)
            guard isCurrent(resources) else {
                throw mappedError
            }
            collectionState = .failed(mappedError)
            resumeCollectionWaiter(throwing: mappedError)
            resumeStoppedWaiter(throwing: mappedError)
            resources.session.stateHandler = nil
            resources.session.end()
            clearWorkoutState()
            throw mappedError
        }
    }

    public func finish(at date: Date, metadata: WorkoutMetadata = [:]) async throws {
        let resources = try beginTermination()
        do {
            try await prepareBuilderForTermination(resources, at: date)
            try await resources.builder.finishWorkout(metadata: metadata)
            endSessionIfNeeded(resources.session)
            clearCompletedWorkout(resources.session)
        } catch {
            handleTerminationFailure(resources, error: error)
            if error is CancellationError {
                throw error
            }
            throw mapHealthError(error)
        }
    }

    public func discard(at date: Date) async throws {
        let resources = try beginTermination()
        do {
            try await prepareBuilderForTermination(resources, at: date)
            resources.builder.discardWorkout()
            endSessionIfNeeded(resources.session)
            clearCompletedWorkout(resources.session)
        } catch {
            handleTerminationFailure(resources, error: error)
            if error is CancellationError {
                throw error
            }
            throw mapHealthError(error)
        }
    }

    private func beginTermination() throws -> LiveWorkoutResources {
        switch lifecycle {
        case .idle:
            throw WorkoutControllerError.noActiveWorkout
        case .ending:
            throw WorkoutControllerError.terminationAlreadyInProgress
        case .active, .failed:
            break
        }
        guard let resources else {
            throw WorkoutControllerError.noActiveWorkout
        }
        lifecycle = .ending
        return resources
    }

    private func prepareBuilderForTermination(
        _ resources: LiveWorkoutResources,
        at date: Date
    ) async throws {
        try await waitForCollectionToStart()
        try await stopActivityIfNeeded(resources.session, at: date)

        switch terminationProgress {
        case .collectionEnded, .sessionEnded:
            return
        case .collecting, .stopping, .stopped, .none:
            let endDate = terminationProgress?.endDate ?? date
            try await resources.builder.endCollection(at: endDate)
            terminationProgress = .collectionEnded(endDate)
        }
    }

    private func stopActivityIfNeeded(
        _ session: any WorkoutSessionProtocol,
        at date: Date
    ) async throws {
        if case .failed = observedSessionState {
            recordStoppedIfNeeded(at: date)
            return
        }

        guard observedSessionState != .stopped else {
            recordStoppedIfNeeded(at: date)
            return
        }

        let endDate = terminationProgress?.endDate ?? date
        let shouldStopActivity: Bool
        switch terminationProgress {
        case .collectionEnded, .sessionEnded:
            return
        case .collecting, .stopping, .stopped, .none:
            terminationProgress = .stopping(endDate)
            shouldStopActivity = true
        }

        let waiterID = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard stoppedWaiter == nil else {
                    continuation.resume(throwing: WorkoutControllerError.terminationAlreadyInProgress)
                    return
                }

                timeoutTask?.cancel()
                timeoutTask = nil
                stoppedWaiter = StoppedWaiter(id: waiterID, continuation: continuation)
                timeoutTask = Task { [weak self, stopTimeout] in
                    do {
                        try await stopTimeout.wait()
                    } catch {
                        return
                    }
                    self?.stoppedStateTimedOut(waiterID: waiterID)
                }
                if shouldStopActivity {
                    session.stopActivity(at: endDate)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStoppedWaiter(waiterID: waiterID)
            }
        }
    }

    private func recordStoppedIfNeeded(at date: Date) {
        switch terminationProgress {
        case .collectionEnded, .sessionEnded:
            break
        case .collecting, .stopping, .stopped, .none:
            terminationProgress = .stopped(terminationProgress?.endDate ?? date)
        }
    }

    private func waitForCollectionToStart() async throws {
        switch collectionState {
        case .collecting:
            return
        case let .failed(error):
            throw error
        case .notStarted:
            throw WorkoutControllerError.noActiveWorkout
        case .starting:
            break
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard collectionWaiter == nil else {
                continuation.resume(throwing: WorkoutControllerError.terminationAlreadyInProgress)
                return
            }
            collectionWaiter = continuation
        }
    }

    private func receive(_ state: WorkoutSessionState) {
        observedSessionState = state
        switch state {
        case .stopped:
            if case let .stopping(date) = terminationProgress {
                terminationProgress = .stopped(date)
            }
            resumeStoppedWaiter()
        case let .failed(error):
            let mappedError = mapHealthError(error)
            if lifecycle != .ending {
                lifecycle = .failed(mappedError)
            }
            resumeStoppedWaiter(throwing: mappedError)
        case .notStarted, .prepared, .running, .paused, .ended:
            break
        }
    }

    private func stoppedStateTimedOut(waiterID: UUID) {
        resumeStoppedWaiter(waiterID: waiterID, throwing: WorkoutControllerError.stoppedStateTimedOut)
    }

    private func cancelStoppedWaiter(waiterID: UUID) {
        resumeStoppedWaiter(waiterID: waiterID, throwing: CancellationError())
    }

    private func resumeStoppedWaiter(
        waiterID: UUID? = nil,
        throwing error: (any Error)? = nil
    ) {
        guard let stoppedWaiter else { return }
        guard waiterID == nil || stoppedWaiter.id == waiterID else { return }
        self.stoppedWaiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let error {
            stoppedWaiter.continuation.resume(throwing: error)
        } else {
            stoppedWaiter.continuation.resume()
        }
    }

    private func resumeCollectionWaiter(throwing error: (any Error)? = nil) {
        guard let collectionWaiter else { return }
        self.collectionWaiter = nil
        if let error {
            collectionWaiter.resume(throwing: error)
        } else {
            collectionWaiter.resume()
        }
    }

    private func handleTerminationFailure(
        _ resources: LiveWorkoutResources,
        error: any Error
    ) {
        guard isCurrent(resources) else { return }
        if case .collectionEnded = terminationProgress {
            endSessionIfNeeded(resources.session)
        }
        if case let .failed(healthError) = observedSessionState {
            lifecycle = .failed(mapHealthError(healthError))
        } else {
            lifecycle = .active
        }
    }

    private func endSessionIfNeeded(_ session: any WorkoutSessionProtocol) {
        guard case let .collectionEnded(date) = terminationProgress else { return }
        session.end()
        terminationProgress = .sessionEnded(date)
    }

    private func clearCompletedWorkout(_ session: any WorkoutSessionProtocol) {
        session.stateHandler = nil
        clearWorkoutState()
    }

    private func clearWorkoutState() {
        let resetError = WorkoutControllerError.noActiveWorkout
        resumeCollectionWaiter(throwing: resetError)
        resumeStoppedWaiter(throwing: resetError)
        timeoutTask?.cancel()
        timeoutTask = nil
        resources = nil
        collectionState = .notStarted
        terminationProgress = nil
        observedSessionState = .notStarted
        lifecycle = .idle
    }

    private func isCurrent(_ candidate: LiveWorkoutResources) -> Bool {
        guard let resources else { return false }
        return resources.session === candidate.session && resources.builder === candidate.builder
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
