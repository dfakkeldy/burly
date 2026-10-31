// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §4 at the level of a Burly session: when to ask for Health access,
// when a live workout starts and ends, and what the recovery matrix does
// after a relaunch. `WorkoutController` stays the only owner of the ordered
// end sequence; this type decides *whether* and *for which session* to run it.
//
// Health is best-effort. Sets are app data and live in the Burly store; a
// declined prompt, a missing device capability, a HealthKit failure or a
// slow HealthKit call never surfaces as an error and never blocks the store
// write (§4 acceptance #4). Every HealthKit call except the authorization
// prompt is bounded by `timeout`, so a stuck callback cannot hold Finish.
//
// Operations run strictly one at a time, in call order. The order slot is
// taken synchronously when a method is called, so a caller can fire
// `sessionDidStart` and later await `sessionDidFinish` without the finish
// overtaking a start that is still waiting on the authorization sheet.
import Foundation

@MainActor
public final class SessionWorkoutRecorder {
    private let store: any WorkoutHealthStore
    private let controller: WorkoutController
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var tail: Task<Void, Never>?

    /// The Burly session the live workout belongs to, if one is running.
    public private(set) var liveSessionID: UUID?

    public init(
        store: any WorkoutHealthStore,
        controller: WorkoutController,
        timeout: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.controller = controller
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Session events

    /// Spec §4 "Requested at first session start, not app launch": the
    /// first call with an undetermined status shows the system prompt.
    /// With access granted, starts the live workout at the session's start.
    @discardableResult
    public func sessionDidStart(sessionID: UUID, at date: Date) -> Task<Void, Never> {
        enqueue { [self] in
            if store.authorizationStatus == .notDetermined {
                try? await store.requestAuthorization()
            }
            guard store.authorizationStatus == .authorized else { return }
            await discardLiveWorkout()
            guard case .finished(.success) = await bounded({ [controller] in
                try await controller.start(at: date)
            }) else { return }
            liveSessionID = sessionID
        }
    }

    /// Saves the session's workout. A live workout for this session runs
    /// the end sequence; otherwise, when Health access is granted, a
    /// duration-only workout is saved unless one is already linked
    /// (recovery matrix row 2, and the guard against a second write after a
    /// crash between the HealthKit save and the store save).
    public func sessionDidFinish(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date
    ) async -> WorkoutRecording {
        await enqueue { [self] in
            let metadata = WorkoutMetadata.linking(sessionID: sessionID)
            if liveSessionID == sessionID {
                switch await bounded({ [controller] in
                    try await controller.finish(at: endedAt, metadata: metadata)
                }) {
                case let .finished(.success(workoutID)):
                    liveSessionID = nil
                    return .live(workoutID: workoutID)
                case .finished(.failure):
                    // Clean up what is left, then fall through to the
                    // duration-only save; the linked-workout check below
                    // keeps a half-finished save from being doubled.
                    await discardLiveWorkout()
                case .timedOut:
                    // The end sequence may still complete on its own, so a
                    // second save here could duplicate it.
                    return .notSaved
                }
            }

            guard store.authorizationStatus == .authorized else { return .notSaved }
            switch await bounded({ [store] in try await store.workoutCount(linkedTo: sessionID) }) {
            case .finished(.success(0)):
                break
            case let .finished(.success(count)) where count > 0:
                return .alreadySaved
            default:
                // Burly cannot tell whether one exists; saving blind could
                // write a duplicate.
                return .notSaved
            }
            guard case let .finished(.success(workoutID)) = await bounded({ [store] in
                try await store.saveDurationOnlyWorkout(start: startedAt, end: endedAt, metadata: metadata)
            }) else { return .notSaved }
            return .retrospective(workoutID: workoutID)
        }
    }

    /// Spec §4: the discard path never persists an HKWorkout.
    @discardableResult
    public func sessionDidDiscard(sessionID: UUID) -> Task<Void, Never> {
        enqueue { [self] in
            guard liveSessionID == sessionID else { return }
            await discardLiveWorkout()
        }
    }

    /// Recovery matrix at launch. With an active Burly session, a workout
    /// HealthKit kept running is reattached to it (row 1); with none, the
    /// orphan is ended and discarded quietly (row 3). Pass `nil` only when
    /// the store positively has no active session, never when it could not
    /// be read.
    @discardableResult
    public func reconcile(activeSessionID: UUID?) -> Task<Void, Never> {
        enqueue { [self] in
            guard liveSessionID == nil, controller.lifecycle == .idle else { return }
            guard case let .finished(.success(recovered?)) = await bounded({ [store] in
                try await store.recoverLiveWorkout()
            }) else { return }
            do {
                try controller.adopt(recovered)
            } catch {
                return
            }
            if let activeSessionID {
                liveSessionID = activeSessionID
            } else {
                await discardLiveWorkout()
            }
        }
    }

    // MARK: - Internals

    /// Discards whatever live workout the controller owns, bounded.
    private func discardLiveWorkout() async {
        liveSessionID = nil
        switch controller.lifecycle {
        case .active, .failed:
            _ = await bounded({ [controller, now] in
                try await controller.discard(at: now())
            })
        case .idle, .ending:
            break
        }
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in _ = await task.value }
        return task
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let task: Task<T, Never> = enqueue(operation)
        return await task.value
    }

    private func bounded<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async -> BoundedOutcome<T> {
        let race = Race<T>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.timer = Task { @MainActor [sleep, timeout] in
                do {
                    try await sleep(timeout)
                } catch {
                    return
                }
                race.settle(.timedOut)
            }
            Task { @MainActor in
                do {
                    race.settle(.finished(.success(try await operation())))
                } catch {
                    race.settle(.finished(.failure(error)))
                }
            }
        }
    }
}

private enum BoundedOutcome<T> {
    case finished(Result<T, any Error>)
    case timedOut
}

@MainActor
private final class Race<T> {
    var continuation: CheckedContinuation<BoundedOutcome<T>, Never>?
    var timer: Task<Void, Never>?

    func settle(_ outcome: sending BoundedOutcome<T>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: outcome)
    }
}
