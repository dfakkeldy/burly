// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
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

/// Spec §4's HealthKit store operations outside one live workout.
@MainActor
public final class HealthKitWorkoutStore: WorkoutHealthStore {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        assert(WorkoutMetadataKey.externalUUID == HKMetadataKeyExternalUUID)
        assert(WorkoutMetadataKey.brandName == HKMetadataKeyWorkoutBrandName)
        self.healthStore = healthStore
    }

    /// A live-workout factory on the same `HKHealthStore`.
    public func makeSessionFactory() -> HealthKitWorkoutSessionFactory {
        HealthKitWorkoutSessionFactory(healthStore: healthStore)
    }

    public var authorizationStatus: WorkoutAuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
        case .notDetermined: return .notDetermined
        case .sharingDenied: return .denied
        case .sharingAuthorized: return .authorized
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async throws {
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
            )
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
    }

    public func recoverLiveWorkout() async throws -> LiveWorkoutResources? {
        #if os(watchOS)
        let recovered: HKWorkoutSession?
        do {
            recovered = try await healthStore.recoverActiveWorkoutSession()
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
        guard let session = recovered else { return nil }
        let builder = session.associatedWorkoutBuilder()
        if builder.dataSource == nil {
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: session.workoutConfiguration
            )
        }
        return LiveWorkoutResources(
            session: HealthKitWorkoutSessionAdapter(session: session),
            builder: HealthKitLiveWorkoutBuilderAdapter(builder: builder)
        )
        #else
        return nil
        #endif
    }

    public func workoutCount(linkedTo sessionID: UUID) async throws -> Int {
        try await linkedWorkouts(sessionID).count
    }

    public func saveDurationOnlyWorkout(
        start: Date,
        end: Date,
        metadata: WorkoutMetadata
    ) async throws -> UUID? {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = WorkoutActivity.traditionalStrengthTraining.healthKitValue
        configuration.locationType = WorkoutLocation.indoor.healthKitValue
        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: configuration,
            device: .local()
        )
        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata(metadata)
            try await builder.endCollection(at: end)
            return try await builder.finishWorkout()?.uuid
        } catch {
            builder.discardWorkout()
            throw WorkoutHealthError(healthKitError: error)
        }
    }

    public func deleteWorkouts(linkedTo sessionID: UUID) async throws -> Int {
        let workouts = try await linkedWorkouts(sessionID)
        guard !workouts.isEmpty else { return 0 }
        do {
            try await healthStore.delete(workouts)
        } catch {
            throw WorkoutHealthError(healthKitError: error)
        }
        return workouts.count
    }

    private func linkedWorkouts(_ sessionID: UUID) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: [sessionID.uuidString]
        )
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: []
        )
        do {
            return try await query.result(for: healthStore)
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
    private let eventContinuation: AsyncStream<WorkoutSessionState>.Continuation
    private var eventTask: Task<Void, Never>?

    init(session: HKWorkoutSession) {
        self.session = session
        let (events, continuation) = AsyncStream.makeStream(of: WorkoutSessionState.self)
        eventContinuation = continuation
        super.init()
        session.delegate = self
        eventTask = Task { @MainActor [weak self] in
            for await state in events {
                guard let self else { return }
                stateHandler?(state)
            }
        }
    }

    isolated deinit {
        eventContinuation.finish()
        eventTask?.cancel()
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
        eventContinuation.yield(WorkoutSessionState(healthKitState: toState))
    }

    nonisolated func workoutSession(_: HKWorkoutSession, didFailWithError error: any Error) {
        eventContinuation.yield(.failed(WorkoutHealthError(healthKitError: error)))
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

    func finishWorkout(metadata: WorkoutMetadata) async throws -> UUID? {
        do {
            if !metadata.isEmpty {
                try await builder.addMetadata(metadata)
            }
            return try await builder.finishWorkout()?.uuid
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
