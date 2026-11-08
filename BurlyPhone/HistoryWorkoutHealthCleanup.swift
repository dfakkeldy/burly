// SPDX-License-Identifier: MIT
// Removing a deleted session's workout from Apple Health (spec §1 deletion
// rule; §4 "Deleting a session (phone) deletes its HKWorkout via the
// ExternalUUID predicate").
//
// Burly's own delete comes first and does not wait for this: the session
// is already gone from the store, History and Stats by the time Health is
// asked anything, and nothing here can undo or block that. What this file
// owns is the second half, and being honest about how it went. The outcome
// is reported back so History can say plainly when the Health copy is
// still there and how to remove it, because there are ordinary reasons it
// will be:
//
// - The phone asks for HealthKit access only here, the first time a linked
//   workout is deleted, and only to share (write) workouts — the narrowest
//   grant that permits a delete, and inside §4's authorization set. The
//   user can say no.
// - HealthKit lets an app delete only what its own source saved. Burly's
//   workouts are saved by the watch app, and whether the iPhone app counts
//   as the same source for a delete has not been checked on a device. If it
//   does not, `delete` fails or the share-only query finds nothing, and the
//   user is told to remove the workout in the Health app.
//
// Every HealthKit call except the permission prompt is bounded (10 s), the
// same rule the watch's `SessionWorkoutRecorder` follows, so a stuck
// callback ends in "couldn't confirm" rather than silence.
//
// UI-test scenarios never reach HealthKit: the system permission sheet
// would cover the screens the tests drive, and `simctl privacy` cannot
// pre-grant Health (see DECISIONS.md, 2026-10-29). They get a scripted
// remover instead.

import Foundation
import BurlyCore
import BurlyHealth
import HealthKit

/// How the Health half of a history delete went.
enum HealthWorkoutRemoval: Equatable, Sendable {
    /// HealthKit deleted this many linked workouts.
    case removed(count: Int)
    /// The query found no workout linked to the session. Either it is
    /// already gone, or this app cannot see it (see the file doc).
    case notFound
    /// The user has not allowed Burly to change workouts in Health.
    case notAuthorized
    /// Health is not available on this device.
    case unavailable
    /// HealthKit refused or failed the query or the delete.
    case failed
    /// HealthKit did not answer within the bound.
    case timedOut
}

/// The one operation a history delete needs from Health, so the view model
/// can be driven by a scripted double in UI tests.
@MainActor
protocol HealthWorkoutRemoving: AnyObject, Sendable {
    func removeWorkouts(linkedTo sessionID: UUID) async -> HealthWorkoutRemoval
}

@MainActor
final class HealthKitWorkoutRemover: HealthWorkoutRemoving {
    private let timeout: Duration
    /// Built on first use, so constructing the view model (and every
    /// SwiftUI preview) never touches HealthKit.
    private var healthStore: HKHealthStore?

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    func removeWorkouts(linkedTo sessionID: UUID) async -> HealthWorkoutRemoval {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let healthStore = self.healthStore ?? HKHealthStore()
        self.healthStore = healthStore
        let workouts = HealthKitWorkoutStore(healthStore: healthStore)

        if workouts.authorizationStatus == .notDetermined {
            // Share (write) workouts only. Not `HealthKitWorkoutStore
            // .requestAuthorization()`, which also asks to read heart rate
            // and energy: the phone collects neither. A declined or failed
            // prompt falls through to the status check below.
            try? await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        }
        guard workouts.authorizationStatus == .authorized else { return .notAuthorized }

        return await bounded(timeout) {
            do {
                let count = try await workouts.deleteWorkouts(linkedTo: sessionID)
                return count > 0 ? .removed(count: count) : .notFound
            } catch {
                return .failed
            }
        }
    }

    /// Races `operation` against `timeout`; the first to finish answers.
    /// The operation is not cancelled on a timeout (HealthKit may still
    /// complete it); its late answer is simply ignored.
    private func bounded(
        _ timeout: Duration,
        _ operation: @escaping @MainActor () async -> HealthWorkoutRemoval
    ) async -> HealthWorkoutRemoval {
        let race = RemovalRace()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.timer = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                race.settle(.timedOut)
            }
            Task { @MainActor in
                race.settle(await operation())
            }
        }
    }
}

@MainActor
private final class RemovalRace {
    var continuation: CheckedContinuation<HealthWorkoutRemoval, Never>?
    var timer: Task<Void, Never>?

    func settle(_ outcome: HealthWorkoutRemoval) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: outcome)
    }
}

/// What History tells the user after a delete whose Health half did not
/// clearly succeed. `nil` when it did: the confirmation already said Burly
/// would ask Health, and success needs no second message. One per deleted
/// session, named in the title, so two deletes in a row each keep their
/// own report.
struct HistoryNotice: Equatable, Identifiable {
    /// The deleted session's id.
    let id: UUID
    let title: String
    let message: String
    var systemImage = "heart.text.square"

    /// A swipe delete whose store save failed. The session is still there,
    /// so this says so rather than leaving the row to look undeleted.
    init(deleteFailedFor session: SessionData, error: any Error) {
        id = session.id
        title = "Couldn't delete: \(Self.workoutName(session))"
        message = "It's still in your history. \(error.localizedDescription)"
        systemImage = "exclamationmark.triangle"
    }

    private static func workoutName(_ session: SessionData) -> String {
        "\(session.routineName ?? "Workout"), \(session.startedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    init?(afterRemoving outcome: HealthWorkoutRemoval, from session: SessionData) {
        let removeItYourself = "To remove it, open the Health app and delete it from your workouts."
        let reason: String
        switch outcome {
        case .removed:
            return nil
        case .notFound:
            reason = "Burly couldn't find its copy of this workout in Apple Health, so it may still be there."
        case .notAuthorized:
            reason = "Burly isn't allowed to change workouts in Apple Health, so its copy of this workout is still there."
        case .unavailable:
            reason = "Apple Health isn't available on this iPhone, so Burly couldn't remove its copy of this workout."
        case .failed:
            reason = "Apple Health didn't let Burly remove its copy of this workout."
        case .timedOut:
            reason = "Apple Health didn't answer, so Burly couldn't confirm its copy of this workout was removed."
        }
        id = session.id
        title = "Deleted from Burly: \(Self.workoutName(session))"
        message = "\(reason) \(removeItYourself)"
    }
}

#if DEBUG
/// The scripted remover every UI-test scenario gets (see the file doc).
/// `BURLY_PHONE_UI_TEST_HEALTH_REMOVAL` picks the outcome; unset, it is
/// `.failed`, the path whose message a test most needs to see.
@MainActor
final class UITestHealthWorkoutRemover: HealthWorkoutRemoving {
    static let outcomeKey = "BURLY_PHONE_UI_TEST_HEALTH_REMOVAL"

    private let outcome: HealthWorkoutRemoval

    init(outcome: HealthWorkoutRemoval) {
        self.outcome = outcome
    }

    /// Non-nil whenever a UI-test scenario is running, so those launches
    /// can never reach the real HealthKit.
    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> UITestHealthWorkoutRemover? {
        guard environment[PhoneDemoSeed.environmentKey] != nil else { return nil }
        let outcome: HealthWorkoutRemoval = switch environment[outcomeKey] ?? "" {
        case "removed": .removed(count: 1)
        case "notFound": .notFound
        case "notAuthorized": .notAuthorized
        default: .failed
        }
        return UITestHealthWorkoutRemover(outcome: outcome)
    }

    func removeWorkouts(linkedTo sessionID: UUID) async -> HealthWorkoutRemoval {
        outcome
    }
}
#endif
