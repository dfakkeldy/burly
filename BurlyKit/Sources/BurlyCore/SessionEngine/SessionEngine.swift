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
    ///
    /// **Atomic.** If the write cannot happen — no reps, unknown item, a
    /// session already finished — nothing moves: the guarded control is
    /// left exactly as it was, and no haptic is produced for a set that
    /// does not exist. That ordering is load-bearing rather than tidy.
    /// Locking first and discovering the refusal second would leave the
    /// lifter with a control that silently disarmed itself, one buzz that
    /// promised a logged set, and no set.
    @discardableResult
    public mutating func logSet(
        itemID: UUID,
        weight: Weight,
        reps: Int,
        isWarmup: Bool = false,
        makeID: () -> UUID = UUID.init
    ) throws -> LogSetOutcome {
        try performLog(
            gesture: .logSet,
            itemID: itemID,
            weight: weight,
            reps: reps,
            isWarmup: isWarmup,
            makeID: makeID
        )
    }

    /// §2 Double Tap: "performs the primary action = Log set with current
    /// values … Never arms weight editing."
    ///
    /// One call, because the spec describes one action. The weight is
    /// whatever the control currently holds — that is what "current values"
    /// means, and it is why this does not take a weight. Callers never wire
    /// `logsSet` themselves: a caller that forgot to would ship a pinch
    /// gesture that locks the weight and logs nothing, which is exactly the
    /// bug the gesture exists to avoid.
    @discardableResult
    public mutating func handleDoubleTap(
        itemID: UUID,
        reps: Int,
        isWarmup: Bool = false,
        makeID: () -> UUID = UUID.init
    ) throws -> LogSetOutcome {
        try performLog(
            gesture: .doubleTap,
            itemID: itemID,
            weight: weightEdit.weight,
            reps: reps,
            isWarmup: isWarmup,
            makeID: makeID
        )
    }

    /// The shared body of the two logging entry points. `gesture` is the
    /// §2 event that caused the log, and only decides which of the two
    /// identical lock paths the machine takes.
    private mutating func performLog(
        gesture: WeightEditEvent,
        itemID: UUID,
        weight: Weight,
        reps: Int,
        isWarmup: Bool,
        makeID: () -> UUID
    ) throws -> LogSetOutcome {
        // Ask before acting, so a refusal costs nothing.
        try SessionMutator.validateLogSet(itemID: itemID, reps: reps, in: session)

        // Rule 1: the auto-lock is part of logging, and its haptic precedes
        // the success haptic because the control locks as the button is
        // pressed.
        var haptics = weightEditMachine.handle(gesture, &weightEdit).haptics

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

    /// Feeds a gesture to the guarded weight control (§2) and nothing else.
    ///
    /// This is the low-level seam: it moves the lock state and reports what
    /// the gesture implies. It does **not** log. For the two events that
    /// mean "log a set" — `.logSet` and `.doubleTap` — call `logSet(…)` or
    /// `handleDoubleTap(…)` instead, which perform the write as one step.
    @discardableResult
    public mutating func handleWeightEdit(_ event: WeightEditEvent) -> WeightEditEffect {
        weightEditMachine.handle(event, &weightEdit)
    }

    /// Seeds the weight control from a prefill (§2 input model) without
    /// arming it.
    public mutating func prefillWeight(_ weight: Weight) {
        weightEdit.prefill(weight)
    }

    /// The item the watch UI is currently showing (m2-06 review finding
    /// 1.1) -- see `ActiveSession.currentItemID`'s doc. Pure bookkeeping:
    /// this enforces no rule of its own (no validation that `itemID` names
    /// a real, unskipped item), the same way `prefillWeight` above sets a
    /// value without judging it. The caller (`SessionViewModel`) is the
    /// only thing that knows "which page is on screen," and this is just
    /// where that fact rides along so it gets journaled with everything
    /// else `saveActiveSession` persists in one transaction.
    public mutating func setCurrentItem(_ itemID: UUID?) {
        session.currentItemID = itemID
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
    ///
    /// Scoped to the item throughout: the digest is matched against *this*
    /// item's exercise, and the "previous set this session" fallback sees
    /// only this item's own sets. After a swap that split a part-logged
    /// exercise, the new half starts with nothing logged, so it prefills
    /// from its own digest or from empty — never from the weights the
    /// lifter was using for the exercise they just left.
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

    /// §2 "swap exercise". Returns the item the lifter is now working: the
    /// same one for an in-place swap, or the new half when the swap split a
    /// part-logged exercise in two (see `SessionMutator.swapExercise`). The
    /// pager should route to the returned id.
    @discardableResult
    public mutating func swapExercise(
        itemID: UUID,
        toExerciseID exerciseID: UUID?,
        makeID: () -> UUID = UUID.init
    ) throws -> UUID {
        try SessionMutator.swapExercise(
            itemID: itemID,
            toExerciseID: exerciseID,
            in: &session,
            makeID: makeID
        )
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
    ///
    /// - Returns: the haptics of the closing lock transition, so finishing
    ///   with the weight still armed buzzes like every other lock (§2:
    ///   "every lock/unlock transition is a distinct haptic"). Discarding
    ///   them here would make Finish the one transition that is silent.
    @discardableResult
    public mutating func finish() throws -> [HapticEvent] {
        try SessionMutator.finish(&session, clock: clock)
        return weightEditMachine.handle(.pageAway, &weightEdit).haptics
    }
}
