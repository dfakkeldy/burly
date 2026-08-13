// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(HealthKit) && (os(iOS) || os(watchOS))
import Foundation
import HealthKit

@MainActor
public final class HealthKitWorkoutSessionFactory: WorkoutSessionCreating {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func makeLiveWorkout(configuration: WorkoutConfiguration) throws -> LiveWorkoutResources {
        let healthConfiguration = HKWorkoutConfiguration()
        healthConfiguration.activityType = configuration.activity.healthKitValue
        healthConfiguration.locationType = configuration.location.healthKitValue

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: healthConfiguration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: healthConfiguration
            )
            return LiveWorkoutResources(
                session: HealthKitWorkoutSessionAdapter(session: session),
                builder: HealthKitLiveWorkoutBuilderAdapter(builder: builder)
            )
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
    }
}

@MainActor
private final class HealthKitWorkoutSessionAdapter: NSObject, WorkoutSessionProtocol,
    HKWorkoutSessionDelegate
{
    var stateHandler: (@MainActor @Sendable (WorkoutSessionState) -> Void)?
    private let session: HKWorkoutSession

    init(session: HKWorkoutSession) {
        self.session = session
        super.init()
        session.delegate = self
    }

    func startActivity(at date: Date) {
        session.startActivity(with: date)
    }

    func stopActivity(at date: Date) {
        session.stopActivity(with: date)
    }

    func end() {
        session.end()
    }

    nonisolated func workoutSession(
        _: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from _: HKWorkoutSessionState,
        date _: Date
    ) {
        let state = WorkoutSessionState(healthKitState: toState)
        Task { @MainActor [weak self] in
            self?.stateHandler?(state)
        }
    }

    nonisolated func workoutSession(_: HKWorkoutSession, didFailWithError error: any Error) {
        let failure = WorkoutHealthError(healthKitError: error)
        Task { @MainActor [weak self] in
            self?.stateHandler?(.failed(failure))
        }
    }
}

@MainActor
private final class HealthKitLiveWorkoutBuilderAdapter: LiveWorkoutBuilding {
    private let builder: HKLiveWorkoutBuilder

    init(builder: HKLiveWorkoutBuilder) {
        self.builder = builder
    }

    func beginCollection(at date: Date) async throws {
        do {
            try await builder.beginCollection(at: date)
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
    }

    func endCollection(at date: Date) async throws {
        do {
            try await builder.endCollection(at: date)
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
    }

    func finishWorkout(metadata: WorkoutMetadata) async throws {
        do {
            if !metadata.isEmpty {
                try await builder.addMetadata(metadata)
            }
            _ = try await builder.finishWorkout()
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
    }

    func discardWorkout() {
        builder.discardWorkout()
    }
}

private extension WorkoutActivity {
    var healthKitValue: HKWorkoutActivityType {
        switch self {
        case .traditionalStrengthTraining: .traditionalStrengthTraining
        }
    }
}

private extension WorkoutLocation {
    var healthKitValue: HKWorkoutSessionLocationType {
        switch self {
        case .indoor: .indoor
        }
    }
}

private extension WorkoutSessionState {
    init(healthKitState: HKWorkoutSessionState) {
        switch healthKitState {
        case .notStarted: self = .notStarted
        case .prepared: self = .prepared
        case .running: self = .running
        case .paused: self = .paused
        case .stopped: self = .stopped
        case .ended: self = .ended
        @unknown default:
            self = .failed(.operationFailed("Unknown HealthKit workout session state"))
        }
    }
}

private extension WorkoutHealthError {
    init(healthKitError error: any Error) {
        if let healthError = error as? HKError,
           healthError.code == .errorAnotherWorkoutSessionStarted
        {
            self = .anotherWorkoutSessionStarted
        } else {
            self = .operationFailed(String(describing: error))
        }
    }
}
#endif
