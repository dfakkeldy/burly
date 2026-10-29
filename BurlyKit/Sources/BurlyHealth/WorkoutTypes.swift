// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HealthKit-independent values that are safe to compile on the macOS test host.
public enum WorkoutActivity: Sendable, Equatable {
    case traditionalStrengthTraining
}

public enum WorkoutLocation: Sendable, Equatable {
    case indoor
}

public struct WorkoutConfiguration: Sendable, Equatable {
    public var activity: WorkoutActivity
    public var location: WorkoutLocation

    public init(activity: WorkoutActivity, location: WorkoutLocation) {
        self.activity = activity
        self.location = location
    }
}

public typealias WorkoutMetadata = [String: String]

public enum WorkoutHealthError: Error, Sendable, Equatable {
    case anotherWorkoutSessionStarted
    case operationFailed(String)
}

public enum WorkoutSessionState: Sendable, Equatable {
    case notStarted
    case prepared
    case running
    case paused
    case stopped
    case ended
    case failed(WorkoutHealthError)
}

public enum WorkoutLifecycle: Sendable, Equatable {
    case idle
    case active
    case ending
    case failed(WorkoutControllerError)
}

public enum WorkoutControllerError: Error, Sendable, Equatable {
    case workoutAlreadyActive
    case noActiveWorkout
    case terminationAlreadyInProgress
    case anotherWorkoutSessionStarted
    case stoppedStateTimedOut
    case healthOperationFailed(WorkoutHealthError)
}

/// Spec §4 linking keys, spelled out so this target compiles without
/// HealthKit. `HealthKitWorkoutAdapters.swift` asserts they equal
/// `HKMetadataKeyExternalUUID` and `HKMetadataKeyWorkoutBrandName`.
public enum WorkoutMetadataKey {
    public static let externalUUID = "HKExternalUUID"
    public static let brandName = "HKWorkoutBrandName"
}

public extension WorkoutMetadata {
    /// The metadata every Burly workout carries, live or retrospective:
    /// the session id as the queryable external link, and the brand name.
    static func linking(sessionID: UUID) -> WorkoutMetadata {
        [
            WorkoutMetadataKey.externalUUID: sessionID.uuidString,
            WorkoutMetadataKey.brandName: "Burly"
        ]
    }
}

/// Whether Burly may save workouts. HealthKit only reports the share
/// (write) side; read permission for heart rate and energy is never
/// observable, so it plays no part here.
public enum WorkoutAuthorizationStatus: Sendable, Equatable {
    /// Health data does not exist on this device.
    case unavailable
    case notDetermined
    case denied
    case authorized
}

/// What happened to HealthKit when a session finished.
public enum WorkoutRecording: Sendable, Equatable {
    /// The live workout was saved with sensor data.
    case live(workoutID: UUID?)
    /// No live workout was running, so a duration-only workout was saved
    /// (spec §4 recovery matrix, row 2): no heart rate or energy samples.
    case retrospective(workoutID: UUID?)
    /// A workout linked to this session was already in Health.
    case alreadySaved
    /// Nothing was written: Health is unavailable or declined, or HealthKit
    /// failed. Never shown to the lifter as an error (§4 acceptance #4).
    case notSaved

    public var workoutID: UUID? {
        switch self {
        case let .live(id), let .retrospective(id): id
        case .alreadySaved, .notSaved: nil
        }
    }

    /// True when the saved workout has no sensor data (summary note).
    public var lacksSensorData: Bool {
        if case .retrospective = self { return true }
        return false
    }
}
