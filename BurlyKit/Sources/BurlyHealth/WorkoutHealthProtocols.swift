// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Creates a matched live session and builder without exposing HealthKit types.
/// A future non-live builder is deliberately not part of this live-only factory.
@MainActor
public protocol WorkoutSessionCreating: AnyObject {
    func makeLiveWorkout(configuration: WorkoutConfiguration) throws -> LiveWorkoutResources
}

/// The session lifecycle operations and delegate state stream used by the controller.
@MainActor
public protocol WorkoutSessionProtocol: AnyObject {
    var stateHandler: (@MainActor @Sendable (WorkoutSessionState) -> Void)? { get set }

    func startActivity(at date: Date)
    func stopActivity(at date: Date)
    func end()
}

/// Live-builder operations kept separate from session creation so later non-live
/// workout construction can use its own factory without changing this protocol.
@MainActor
public protocol LiveWorkoutBuilding: AnyObject {
    func beginCollection(at date: Date) async throws
    func endCollection(at date: Date) async throws
    func finishWorkout(metadata: WorkoutMetadata) async throws
    func discardWorkout()
}

/// Injectable wait policy makes the stopped-state deadline deterministic in tests.
public protocol WorkoutStopTimeout: Sendable {
    func wait() async throws
}

public struct LiveWorkoutResources {
    public let session: any WorkoutSessionProtocol
    public let builder: any LiveWorkoutBuilding

    public init(session: any WorkoutSessionProtocol, builder: any LiveWorkoutBuilding) {
        self.session = session
        self.builder = builder
    }
}

public struct FiveSecondWorkoutStopTimeout: WorkoutStopTimeout {
    private let sleep: @Sendable (Duration) async throws -> Void

    public init() {
        sleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    public func wait() async throws {
        try await sleep(.seconds(5))
    }
}
