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

    /// The session whose live start has not answered: still in flight, or
    /// timed out but possibly finishing later in HealthKit. A takeover in
    /// that window belongs to this session, though `liveSessionID` is
    /// never set for it.
    private var startingSessionID: UUID?

    /// Sessions whose live workout another app's workout took over, or
    /// kept from starting (§4), oldest first. Kept in `marks` because
    /// watchOS can end Burly once its workout is gone: a lifter who
    /// reopens it and finishes must still get no overlapping workout.
    private var supersededSessionIDs: [UUID]
    private let marks: SupersededSessionMarks

    /// Enough for any realistic run of interrupted sessions; the oldest
    /// marks go first, since Finish or Discard normally clears each one.
    private static let markLimit = 16

    public init(
        store: any WorkoutHealthStore,
        controller: WorkoutController,
        timeout: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        marks: SupersededSessionMarks = .none
    ) {
        self.store = store
        self.controller = controller
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
        self.marks = marks
        supersededSessionIDs = marks.load()
        controller.onAnotherWorkoutStarted = { [weak self] in
            guard let self, let sessionID = self.liveSessionID ?? self.startingSessionID else { return }
            self.markSuperseded(sessionID)
        }
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
            startingSessionID = sessionID
            switch await bounded({ [controller] in try await controller.start(at: date) }) {
            case .finished(.success):
                startingSessionID = nil
                liveSessionID = sessionID
                // A takeover that landed between the start finishing and
                // this line found no live session to mark.
                if controller.lifecycle == .failed(.anotherWorkoutSessionStarted) {
                    markSuperseded(sessionID)
                }
            case let .finished(.failure(error)) where Self.isAnotherWorkout(error):
                startingSessionID = nil
                markSuperseded(sessionID)
            case .finished(.failure):
                startingSessionID = nil
            case .timedOut:
                // HealthKit may still start it; `startingSessionID` stays,
                // so a takeover after that is marked for this session.
                break
            }
        }
    }

    /// §4: true once another app's workout has taken over this session's
    /// live workout, or kept it from starting, in this launch or an
    /// earlier one. The logging screen polls this to offer "another
    /// workout is running" with finish-or-discard; `sessionDidFinish` then
    /// saves no workout for the session.
    public func anotherWorkoutTookOver(sessionID: UUID) -> Bool {
        if supersededSessionIDs.contains(sessionID) { return true }
        return (liveSessionID ?? startingSessionID) == sessionID
            && controller.lifecycle == .failed(.anotherWorkoutSessionStarted)
    }

    /// Saves the session's workout. A live workout for this session runs
    /// the end sequence; otherwise, when Health access is granted, a
    /// duration-only workout is saved unless one is already linked
    /// (recovery matrix row 2, and the guard against a second write after a
    /// crash between the HealthKit save and the store save).
    ///
    /// When another app's workout took over (§4), nothing is saved: that
    /// app has its own workout for the same time, and a second one from
    /// Burly, live or duration-only, would overlap it in Health. The mark
    /// stays until `sessionWasLogged(sessionID:)`, so a crash before the
    /// store save leaves the next Finish saving nothing too.
    public func sessionDidFinish(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date
    ) async -> WorkoutRecording {
        await enqueue { [self] in
            let metadata = WorkoutMetadata.linking(sessionID: sessionID)
            defer {
                if startingSessionID == sessionID { startingSessionID = nil }
            }
            if anotherWorkoutTookOver(sessionID: sessionID) {
                markSuperseded(sessionID)
                if liveSessionID == sessionID {
                    await discardLiveWorkout()
                }
                return .supersededByAnotherWorkout
            }
            if liveSessionID == sessionID {
                switch await bounded({ [controller] in
                    try await controller.finish(at: endedAt, metadata: metadata)
                }) {
                case let .finished(.success(workoutID)):
                    liveSessionID = nil
                    return .live(workoutID: workoutID)
                case let .finished(.failure(error)):
                    // Clean up what is left, then fall through to the
                    // duration-only save; the linked-workout check below
                    // keeps a half-finished save from being doubled. A
                    // takeover during the end sequence saves nothing.
                    let tookOver = Self.isAnotherWorkout(error)
                        || controller.lifecycle == .failed(.anotherWorkoutSessionStarted)
                    await discardLiveWorkout()
                    if tookOver {
                        markSuperseded(sessionID)
                        return .supersededByAnotherWorkout
                    }
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

    /// The store has saved the session as logged: it can never finish
    /// again, so its another-workout mark, if any, goes.
    public func sessionWasLogged(sessionID: UUID) {
        clearMark(sessionID)
    }

    /// Spec §4: the discard path never persists an HKWorkout.
    @discardableResult
    public func sessionDidDiscard(sessionID: UUID) -> Task<Void, Never> {
        enqueue { [self] in
            clearMark(sessionID)
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

    private static func isAnotherWorkout(_ error: any Error) -> Bool {
        (error as? WorkoutControllerError) == .anotherWorkoutSessionStarted
    }

    private func markSuperseded(_ sessionID: UUID) {
        guard !supersededSessionIDs.contains(sessionID) else { return }
        supersededSessionIDs.append(sessionID)
        supersededSessionIDs = Array(supersededSessionIDs.suffix(Self.markLimit))
        marks.save(supersededSessionIDs)
    }

    private func clearMark(_ sessionID: UUID) {
        guard let index = supersededSessionIDs.firstIndex(of: sessionID) else { return }
        supersededSessionIDs.remove(at: index)
        marks.save(supersededSessionIDs)
    }

    /// Discards whatever live workout the controller owns, bounded.
    private func discardLiveWorkout() async {
        liveSessionID = nil
        startingSessionID = nil
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

/// Where `SessionWorkoutRecorder` keeps the sessions another app's workout
/// took over, so the mark outlives the process.
public struct SupersededSessionMarks {
    public var load: @MainActor () -> [UUID]
    public var save: @MainActor ([UUID]) -> Void

    public init(load: @escaping @MainActor () -> [UUID], save: @escaping @MainActor ([UUID]) -> Void) {
        self.load = load
        self.save = save
    }

    /// Nothing survives the process. For tests and previews.
    public static var none: SupersededSessionMarks {
        SupersededSessionMarks(load: { [] }, save: { _ in })
    }

    /// The watch app's: one string array in `defaults`.
    @MainActor
    public static func userDefaults(
        _ defaults: UserDefaults = .standard,
        key: String = "com.burly.health.supersededSessionIDs"
    ) -> SupersededSessionMarks {
        SupersededSessionMarks(
            load: { (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)) },
            save: { defaults.set($0.map(\.uuidString), forKey: key) }
        )
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
