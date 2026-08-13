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
