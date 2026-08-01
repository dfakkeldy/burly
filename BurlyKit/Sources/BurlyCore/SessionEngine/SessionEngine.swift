// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionEngine
//
// The thin seam that wires the three §2/§3 machines together, so the watch
// UI (m2-03+) binds to one object and no cross-cutting rule is left for a
// view to remember.
//
// There are exactly three such rules, all of them about logging a set:
//
// 1. Logging auto-locks the guarded weight control (§2).
// 2. Logging fires the success haptic (§2).
// 3. Logging auto-starts the rest timer — every set, warmups included —
//    cancelling any running one (§3).
//
// Nothing else lives here. Structural edits pass straight through to
// `SessionMutator`, timer control to `RestTimerEngine`, and gestures to
// `GuardedWeightEditMachine`; this type owns no rules of its own beyond the
// three above, and holds no state the other types do not already define.
//
// Imports Foundation for `UUID`/`Date`/`TimeInterval` only.
import Foundation

/// What one logged set produced.
public struct LogSetOutcome: Sendable, Equatable {
    /// The record that was written.
    public var set: SetRecordData
    /// Haptics to play, in order (lock transition, if any, then success).
    public var haptics: [HapticEvent]
    /// The freshly started rest timer (§3).
    public var restTimer: RestTimerState

    public init(set: SetRecordData, haptics: [HapticEvent], restTimer: RestTimerState) {
        self.set = set
        self.haptics = haptics
        self.restTimer = restTimer
    }
}

/// The watch's live session: an `ActiveSession` plus the two state machines
/// that drive the logging screen.
public struct SessionEngine: Sendable {
    /// The session and its in-flight scaffolding, including the rest timer.
    /// Persist this whole value to survive crash/resume (§2, §3).
    public private(set) var session: ActiveSession

    /// The guarded weight control's state. Not persisted on purpose: after
    /// a relaunch the weight must come back locked, which is the default.
    public private(set) var weightEdit: WeightEditState

    public let clock: any WallClock
    public var restTimer: RestTimerEngine
    public var weightEditMachine: GuardedWeightEditMachine

    public init(
        session: ActiveSession,
        clock: any WallClock = SystemWallClock(),
        restConfiguration: RestTimerConfiguration = RestTimerConfiguration(),
        weightEditConfiguration: GuardedWeightEditMachine.Configuration = .init(),
        initialWeight: Weight = .bodyweight
    ) {
        self.session = session
        self.clock = clock
        self.restTimer = RestTimerEngine(configuration: restConfiguration, clock: clock)
        self.weightEditMachine = GuardedWeightEditMachine(
            configuration: weightEditConfiguration,
            clock: clock
        )
        self.weightEdit = WeightEditState(weight: initialWeight)
    }

    // MARK: - Logging

    /// Writes a set and applies the three logging rules above.
    @discardableResult
    public mutating func logSet(
        itemID: UUID,
        weight: Weight,
        reps: Int,
        isWarmup: Bool = false,
        makeID: () -> UUID = UUID.init
    ) throws -> LogSetOutcome {
        // Rule 1 first: the auto-lock is part of logging, and its haptic
        // precedes the success haptic because the control locks as the
        // button is pressed.
        var haptics = weightEditMachine.handle(.logSet, &weightEdit).haptics

        let record = try SessionMutator.logSet(
            itemID: itemID,
            weight: weight,
            reps: reps,
            isWarmup: isWarmup,
            in: &session,
            clock: clock,
            makeID: makeID
        )

        // Rule 2.
        haptics.append(.setLogged)

        // Rule 3 — unconditional overwrite, which is exactly "cancels any
        // running timer and starts a fresh one" (§3).
        let timer = restTimer.start(
            &session.restTimer,
            itemOverride: session.plan(itemID)?.restOverride
        )

        weightEdit.prefill(weight)
        return LogSetOutcome(set: record, haptics: haptics, restTimer: timer)
    }

    // MARK: - Gestures

    /// Feeds a gesture to the guarded weight control (§2). Returns the
    /// effect; when `logsSet` is true the caller follows up with
    /// `logSet(itemID:…)` using `weightEdit.weight`.
    @discardableResult
    public mutating func handleWeightEdit(_ event: WeightEditEvent) -> WeightEditEffect {
        weightEditMachine.handle(event, &weightEdit)
    }

    /// Seeds the weight control from a prefill (§2 input model) without
    /// arming it.
    public mutating func prefillWeight(_ weight: Weight) {
        weightEdit.prefill(weight)
    }

    /// The pager moved to another exercise: §2 auto-locks the weight.
    @discardableResult
    public mutating func pageAway() -> [HapticEvent] {
        weightEditMachine.handle(.pageAway, &weightEdit).haptics
    }

    // MARK: - Rest timer

    @discardableResult
    public mutating func adjustRest(by delta: TimeInterval) -> [HapticEvent] {
        restTimer.adjust(&session.restTimer, by: delta)
    }

    public mutating func skipRest() {
        restTimer.skip(&session.restTimer)
    }

    public mutating func noteScreenWake() {
        restTimer.noteScreenWake(&session.restTimer)
    }

    public var restRemaining: TimeInterval {
        restTimer.remaining(session.restTimer)
    }

    /// One evaluation pass for the 1 Hz `TimelineView` (§2 Always-On, §3):
    /// the weight control's idle auto-lock and the rest timer's haptic
    /// marks. Correctness never depends on the cadence — both machines
    /// derive their answer from the clock, not from a count of ticks.
    @discardableResult
    public mutating func tick() -> [HapticEvent] {
        var haptics = weightEditMachine.handle(.idleTick, &weightEdit).haptics
        haptics.append(contentsOf: restTimer.tick(&session.restTimer))
        return haptics
    }

    // MARK: - Prefill

    /// §2's prefill for the next set of an item.
    public func prefill(
        forItem itemID: UUID,
        lastPerformance: ExerciseLastPerformanceData?
    ) -> SetPrefill {
        guard let item = session.item(itemID) else { return .empty }
        return SetPrefillResolver.prefill(
            exerciseID: item.exerciseID,
            setIndex: item.sets.count,
            loggedSets: item.sets,
            lastPerformance: lastPerformance
        )
    }

    // MARK: - Structural edits (§2 ellipsis menu)

    public mutating func addSet(toItem itemID: UUID) throws {
        try SessionMutator.addSet(toItem: itemID, in: &session)
    }

    public mutating func removeEmptySet(fromItem itemID: UUID) throws {
        try SessionMutator.removeEmptySet(fromItem: itemID, in: &session)
    }

    public mutating func skipExercise(itemID: UUID) throws {
        try SessionMutator.skipExercise(itemID: itemID, in: &session)
    }

    public mutating func swapExercise(itemID: UUID, toExerciseID exerciseID: UUID?) throws {
        try SessionMutator.swapExercise(itemID: itemID, toExerciseID: exerciseID, in: &session)
    }

    @discardableResult
    public mutating func addExercise(
        exerciseID: UUID?,
        plannedSetCount: Int = 3,
        restOverride: TimeInterval? = nil,
        at index: Int? = nil,
        makeID: () -> UUID = UUID.init
    ) throws -> UUID {
        try SessionMutator.addExercise(
            exerciseID: exerciseID,
            plannedSetCount: plannedSetCount,
            restOverride: restOverride,
            at: index,
            in: &session,
            makeID: makeID
        )
    }

    @discardableResult
    public mutating func addPlaceholderExercise(
        plannedSetCount: Int = 3,
        makeID: () -> UUID = UUID.init
    ) throws -> (itemID: UUID, exercise: ExerciseData) {
        try SessionMutator.addPlaceholderExercise(
            plannedSetCount: plannedSetCount,
            in: &session,
            makeID: makeID
        )
    }

    public mutating func moveItemUp(itemID: UUID) throws {
        try SessionMutator.moveItemUp(itemID: itemID, in: &session)
    }

    public mutating func moveItemDown(itemID: UUID) throws {
        try SessionMutator.moveItemDown(itemID: itemID, in: &session)
    }

    /// §2 Finish. Also locks the weight control and clears the rest timer.
    public mutating func finish() throws {
        try SessionMutator.finish(&session, clock: clock)
        weightEditMachine.handle(.pageAway, &weightEdit)
    }
}
