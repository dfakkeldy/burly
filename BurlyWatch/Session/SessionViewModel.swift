// SPDX-License-Identifier: GPL-3.0-or-later
// Drives the §2 logging screen: owns the `SessionEngine`, persists through
// `BurlyStore.saveActiveSession(_:)` after every mutation (and once more
// after Finish, per that method's doc), and plays the haptics each engine
// operation reports. No session-flow *rule* lives here -- every rule the
// spec states (auto-lock, prefill ladder, invariants, finish semantics)
// already lives in BurlyCore/SessionEngine and is exercised by its own
// Swift Testing suite; this type is wiring, not policy.
//
// Confined to `@MainActor` for the same reason `WatchHomeViewModel` is
// (BurlyStore.swift's threading doc): the store is used from one isolation
// domain, and SwiftUI is that domain here.
//
// ## A lifter mid-workout must never be lied to about whether their sets
// are saved (m2-03 review, blocker + majors 2-9)
//
// This type used to: create and save the session from its own initializer
// (a SwiftUI-construction-time side effect, m2-03 review finding 2 -- the
// engine and the first save now happen once in `SessionEntryView.start()`,
// an explicit event, before this type is ever constructed); invent
// bodyweight×8 defaults for an honestly-empty prefill (finding 3); let
// skip/swap/add bypass the engine's page-away lock (finding 4); gate
// rest-timer persistence on whether a haptic fired rather than on whether
// the timer actually changed (finding 5); and -- the whole cluster this
// doc exists to summarize -- let logging, Finish, placeholder creation, and
// Discard each report success (a haptic, an advance, a dismissal) before
// their `BurlyStore` write had actually succeeded (findings 6-9).
//
// The fix threading through all of the mutating methods below is the same
// shape every time: mutate a **snapshot** of the engine, attempt the store
// write, and only fold the mutation into the real `engine` -- and only play
// the haptic / advance the UI -- once that write has actually succeeded.
// On failure, `saveFailure` is set (blocking the logging screen, see
// `LoggingScreenView`) together with a `pendingRetry` closure that redoes
// exactly the failed attempt; nothing about the failed mutation is visible
// anywhere else in this type's state, because it was never committed to
// `engine` in the first place.
import Foundation
import SwiftUI
import Observation
import BurlyCore
import BurlyPersistence

/// Where a swap/add picker should write its result back to.
///
/// `Hashable`, not `Identifiable` (m2-03 review round 3, final pass): the
/// ellipsis-menu route to this picker is now a `NavigationLink(value:)` /
/// `.navigationDestination(for:)` push inside `SessionActionsView`'s own
/// `NavigationStack` (see that file's doc), which needs `Hashable` --
/// `Identifiable`/`.sheet(item:)` was the presentation style this round
/// replaced.
enum ExercisePickerContext: Hashable {
    /// §2 ellipsis "swap exercise" on this item.
    case swap(itemID: UUID)
    /// §2 ellipsis "add exercise", appended to the end.
    case add
}

@MainActor
@Observable
final class SessionViewModel {
    private var engine: SessionEngine
    private let store: BurlyStore
    private let haptics: HapticPlaying
    private let now: () -> Date

    /// The item currently on screen. `nil` only for a brand-new "Empty
    /// session" with nothing added yet (§2 Start).
    private(set) var currentItemID: UUID?

    /// Scratch reps for the set about to be logged -- not part of
    /// `ActiveSession`, the same way the weight control's lock state isn't
    /// (see `WeightEditState`'s doc): it is re-derived from the §2 prefill
    /// ladder every time the current item changes, never carried over.
    ///
    /// `nil` means the §2 prefill ladder came back `.empty` and the lifter
    /// has not entered a value yet (m2-03 review finding 3) -- there is no
    /// history to prefill from, so there is nothing honest to show, and
    /// logging is refused until this is set (see `logCurrentSet()`). This
    /// is never silently defaulted to a plausible-looking number.
    private(set) var currentReps: Int?

    /// True when the current item's weight prefill came back `.empty` and
    /// the lifter has not armed-and-adjusted a real value yet (m2-03 review
    /// finding 3). The engine's `WeightEditState` always holds a concrete
    /// `Weight` (there is no "no weight" representation there without a
    /// BurlyCore change, which is out of this task's scope per the
    /// dispatcher) -- this flag is what lets the view render that
    /// placeholder honestly (a dash, not "0.0 lb") instead of presenting
    /// the internal zero as if it were real prefill data.
    private(set) var isWeightUnset = false

    /// §2 "End workout": the pre-commit summary preview. Non-nil means the
    /// summary screen is showing; nothing in `engine` has changed yet.
    private(set) var endWorkoutPreview: SessionSummary?

    /// Set once Finish has actually committed -- i.e. `engine.finish()`
    /// succeeded **and** the resulting session was durably saved. The
    /// summary screen switches from Finish/Keep going/Discard to a plain
    /// "Saved" acknowledgement.
    private(set) var finishedSummary: SessionSummary?

    /// True once `engine.finish()` has been called. §2/§4: "Finish is
    /// one-way" -- once true, Keep going and Discard are no longer offered
    /// (the in-memory session is already `.logged`, so a mutation attempt
    /// would be refused), and the only forward paths are `retryFinishSave()`
    /// succeeding or `finishedSummary` landing (m2-03 review finding 6).
    private(set) var isFinishing = false

    /// Non-nil when `engine.finish()` succeeded but the follow-up
    /// `saveActiveSession` failed. `retryFinishSave()` is the only way
    /// forward -- it never calls `engine.finish()` again, because
    /// `SessionMutator.finish` refuses an already-`.logged` session
    /// (m2-03 review finding 6).
    private(set) var finishSaveError: String?

    /// `engine.finish()`'s closing weight-lock haptic, stashed until the
    /// save actually succeeds (m2-03 review findings 6-7's "no success
    /// haptic on failure" principle applies to Finish too) -- it plays from
    /// `persistFinish()`, never from `commitFinish()` itself.
    private var pendingFinishHaptics: [HapticEvent] = []

    /// True once a discard has been committed -- the host view dismisses.
    private(set) var didDiscard = false

    /// Non-nil blocks the whole logging screen with a full-screen retry
    /// state (`SaveFailureView`) -- any failed `saveActiveSession` /
    /// `createExercise` during ordinary logging or mid-session edits lands
    /// here (m2-03 review findings 7-8). Never masquerades as success:
    /// nothing that produced this is folded into `engine`, so the set
    /// counter, ghost row, and prefill all still read exactly as they did
    /// before the failed attempt.
    private(set) var saveFailure: String?

    /// Redoes exactly the attempt that produced `saveFailure`. `nil`
    /// whenever `saveFailure` is `nil`.
    private var pendingRetry: (() -> Void)?

    var pickerContext: ExercisePickerContext?
    var isShowingDiscardStepOne = false
    var isShowingDiscardStepTwo = false

    /// Cache of `BurlyStore.lastPerformance(exerciseID:)` reads, so the
    /// ghost row and prefill ladder don't hit the store on every render.
    /// A failed lookup caches `nil` (see `lastPerformance(for:)`) --
    /// "absent digest renders empty ghosts (no crash, no stale data)" is a
    /// spec requirement (§2 acceptance #5), not just a happy-path default.
    private var digestCache: [UUID: ExerciseLastPerformanceData?] = [:]
    private var exerciseNameCache: [UUID: String] = [:]

    /// - Note: does **not** persist anything (m2-03 review finding 2).
    ///   `engine` arrives already durably saved -- `SessionEntryView
    ///   .start()` is the one explicit Start/Resume event that builds and
    ///   saves a `SessionEngine` -- so a throwaway `SessionViewModel`
    ///   SwiftUI constructs and discards during `State(initialValue:)`
    ///   diffing can no longer write to the store as a side effect of
    ///   existing.
    ///
    /// - Parameter startInSummary: m2-06's Resume flow. §2: "Declining
    ///   resume = normal end-workout summary path" -- a lifter who declines
    ///   the Resume offer (`ResumeSessionView`) lands on exactly the same
    ///   Finish/Keep going/Discard preview "End workout" produces, not a
    ///   separate screen with its own policy. `true` calls
    ///   `requestEndWorkout()` once, before the pager is ever shown, so
    ///   `LoggingScreenView.body` renders `endWorkoutPreview` on the very
    ///   first frame; "Keep going" from there clears it and falls through
    ///   to the ordinary pager -- i.e. resuming anyway -- exactly like
    ///   declining-then-changing-your-mind should behave.
    init(
        engine: SessionEngine,
        store: BurlyStore,
        haptics: HapticPlaying = HapticPlayer(),
        now: @escaping () -> Date = Date.init,
        startInSummary: Bool = false
    ) {
        self.engine = engine
        self.store = store
        self.haptics = haptics
        self.now = now
        self.currentItemID = Self.resolveInitialItem(engine.session)
        refreshPrefill()
        if startInSummary {
            requestEndWorkout()
        }
    }

    /// The page to land on when this view model is constructed -- for a
    /// fresh Start *and* for Resume (m2-06 review finding 1.1).
    ///
    /// Prefers `ActiveSession.currentItemID`, the item last recorded via
    /// `applyCurrentItem`/`engine.setCurrentItem` and journaled with the
    /// rest of the scaffolding -- so Resume genuinely lands where the
    /// lifter left off, including a page move made *after* the last set
    /// they logged, which a "first item with an empty slot" heuristic can
    /// never recover (m2-06 review round 1 finding 1.1's own example: log
    /// on A, page to B, kill with both still incomplete -- the old
    /// heuristic landed back on A). Falls back to the first item that
    /// still has something left to log, then to the first unskipped item,
    /// when the restored id is `nil` (a brand-new session, or a session
    /// saved before this field existed) or names an item that is no longer
    /// unskipped (the lifter skipped it after being on it, or moved on)
    /// -- the same graceful-degradation posture the pre-fix heuristic
    /// already took, kept as a fallback rather than a hard requirement.
    private static func resolveInitialItem(_ active: ActiveSession) -> UUID? {
        let unskipped = active.unskippedItems
        if let restored = active.currentItemID, unskipped.contains(where: { $0.id == restored }) {
            return restored
        }
        return unskipped.first { active.hasEmptySetSlot($0.id) }?.id
            ?? unskipped.first?.id
    }

    // MARK: - Reads

    var items: [SessionItemData] { engine.session.unskippedItems }

    var currentItem: SessionItemData? {
        currentItemID.flatMap { engine.session.item($0) }
    }

    var currentPlannedSetCount: Int {
        currentItemID.map { engine.session.plannedSetCount($0) } ?? 0
    }

    var currentLoggedSetCount: Int {
        currentItemID.map { engine.session.loggedSetCount($0) } ?? 0
    }

    var currentWeight: Weight { engine.weightEdit.weight }
    var isWeightArmed: Bool { engine.weightEdit.isArmed }

    /// §2/§4 honesty: Double Tap and the on-screen Log button both disable
    /// while this is false (m2-03 review finding 3) -- reps has no
    /// legitimate value to log yet, and there is nothing to fabricate one
    /// from.
    var canLogCurrentSet: Bool { currentItemID != nil && currentReps != nil }

    func plannedSetCount(for itemID: UUID) -> Int { engine.session.plannedSetCount(itemID) }
    func loggedSetCount(for itemID: UUID) -> Int { engine.session.loggedSetCount(itemID) }
    func exerciseID(for itemID: UUID) -> UUID? { engine.session.item(itemID)?.exerciseID }

    /// §2's ghost row for the set about to be logged on `itemID` -- pure
    /// per-item, unlike the weight/reps scratch state below, so a `TabView`
    /// page that isn't `currentItemID` (a neighbour mid-swipe) still shows
    /// its own correct ghost rather than the current page's.
    func ghost(for itemID: UUID) -> SetSnapshot? {
        guard let item = engine.session.item(itemID) else { return nil }
        return SetPrefillResolver.ghost(
            exerciseID: item.exerciseID,
            setIndex: item.sets.count,
            lastPerformance: lastPerformance(for: item.exerciseID)
        )
    }

    /// The catalog picker's source list (§2 ellipsis "swap exercise" /
    /// "add exercise"). Sorted by name (`BurlyStore.exercises(includingArchived:)`'s
    /// own contract) -- this is the flat MVP list; sectioning into
    /// recents/curated/customs is a follow-on UI polish item, not a
    /// mutation-correctness one.
    func availableExercises() -> [ExerciseData] {
        (try? store.exercises(includingArchived: false)) ?? []
    }

    func exerciseName(_ exerciseID: UUID?) -> String {
        guard let exerciseID else { return SessionMutator.placeholderExerciseName }
        if let cached = exerciseNameCache[exerciseID] { return cached }
        let fetched: ExerciseData? = (try? store.exercise(id: exerciseID)) ?? nil
        let name = fetched?.name ?? SessionMutator.placeholderExerciseName
        exerciseNameCache[exerciseID] = name
        return name
    }

    var canMoveCurrentUp: Bool {
        guard let id = currentItemID else { return false }
        return SessionMutator.canMoveUp(itemID: id, in: engine.session)
    }

    var canMoveCurrentDown: Bool {
        guard let id = currentItemID else { return false }
        return SessionMutator.canMoveDown(itemID: id, in: engine.session)
    }

    var canRemoveEmptySetOnCurrent: Bool {
        guard let id = currentItemID else { return false }
        return engine.session.hasEmptySetSlot(id)
    }

    // MARK: - Paging (crown / TabView selection)

    /// Backs `TabView(selection:)`. Every transition -- crown-driven paging
    /// included -- funnels through `moveToItem(_:)`, so the §2
    /// auto-lock-on-page-away rule applies uniformly regardless of what
    /// caused the move.
    var pagingSelection: Binding<UUID?> {
        Binding(get: { self.currentItemID }, set: { self.moveToItem($0) })
    }

    func moveToItem(_ id: UUID?) {
        guard id != currentItemID else { return }
        applyCurrentItem(id)
    }

    /// Used after a mutation (swap/add/skip) that may leave `currentItemID`
    /// numerically unchanged but semantically different (a swap in place
    /// changes the exercise under the same item id) -- always refreshes,
    /// never gated on "did the id change."
    ///
    /// **Every** call always fires the engine's `.pageAway` event and plays
    /// whatever haptic it returns (m2-03 review finding 4). The previous
    /// shape let skip/swap/add suppress `engine.pageAway()` itself -- not
    /// just its haptic -- via a `firesPageAwayHaptic` flag, which left the
    /// guarded weight control armed across an exercise change: presentation
    /// code must not suppress a state transition just to suppress a
    /// haptic.
    private func applyCurrentItem(_ id: UUID?) {
        play(engine.pageAway())
        currentItemID = id
        // m2-06 review finding 1.1: record the page for Resume, in the
        // same journaled record `persist()` is about to save -- one
        // transaction, no separate write that a crash between the two
        // could tear apart.
        engine.setCurrentItem(id)
        refreshPrefill()
        persist()
    }

    /// Recomputes the scratch reps and seeds the weight control from the
    /// §2 prefill ladder for whatever `currentItemID` is now. Always sets
    /// the weight explicitly -- `engine.weightEdit` is one value shared by
    /// the whole session, not one per item, so leaving it untouched would
    /// carry the previous exercise's weight onto this one.
    ///
    /// Renders an `.empty` prefill honestly (m2-03 review finding 3): the
    /// engine's `WeightEditState` still needs *some* concrete `Weight` to
    /// seed (0 kg, the same substrate `.bodyweight` uses), but `isWeightUnset`
    /// records that this is a placeholder, not real prefill data, and
    /// `currentReps` stays `nil` rather than defaulting to an invented "8."
    private func refreshPrefill() {
        guard let item = currentItem else {
            engine.prefillWeight(.bodyweight)
            currentReps = nil
            isWeightUnset = true
            return
        }
        let prefill = engine.prefill(forItem: item.id, lastPerformance: lastPerformance(for: item.exerciseID))
        engine.prefillWeight(prefill.weight ?? .bodyweight)
        currentReps = prefill.reps
        isWeightUnset = prefill.weight == nil
    }

    // MARK: - Reps (scratch, no lock -- §2 only guards weight)

    func incrementReps() { currentReps = Swift.max(1, (currentReps ?? 0) + 1) }

    func decrementReps() {
        guard let current = currentReps else { return }
        currentReps = Swift.max(1, current - 1)
    }

    func adjustReps(bySteps steps: Int) {
        guard steps != 0 else { return }
        currentReps = Swift.max(1, (currentReps ?? 0) + steps)
    }

    // MARK: - Guarded weight edit (§2)

    func armWeight() { play(engine.handleWeightEdit(.longPressArm).haptics) }

    /// A real crown/micro-button adjustment is the lifter deliberately
    /// choosing a value -- from this point the control no longer shows the
    /// `isWeightUnset` placeholder, even if the prefill that seeded it was
    /// `.empty` (m2-03 review finding 3).
    func adjustWeight(bySteps steps: Int) {
        let effect = engine.handleWeightEdit(.adjust(steps: steps))
        if effect.weightChanged {
            isWeightUnset = false
        }
        play(effect.haptics)
    }

    // MARK: - Logging (§2 primary action / Double Tap)

    /// The logging screen's one "Log set" control calls this whether it
    /// was tapped on screen or triggered by the watchOS Double Tap
    /// gesture (`.handGestureShortcut(.primaryAction)`, wired in
    /// `LoggingScreenView`) -- both are, per spec, "the primary action ...
    /// with current values," so there is exactly one call site and it can
    /// never accidentally arm the weight control (`SessionEngine
    /// .handleDoubleTap`'s own doc: "Callers never wire `logsSet`
    /// themselves").
    ///
    /// Refuses to log with no reps set (`canLogCurrentSet`) rather than
    /// inventing a value (m2-03 review finding 3), and never reports
    /// success before the write actually durable (m2-03 review finding 7):
    /// the engine mutation is attempted on a **snapshot**, the store write
    /// is attempted before anything is folded back into `engine`, and only
    /// a successful write plays the haptic and advances the prefill. On
    /// failure the snapshot is discarded (never assigned), so the set
    /// counter, ghost row, and prefill all still read exactly as they did
    /// before this call -- the set is genuinely not shown as logged, not
    /// just silently unsaved in the background.
    func logCurrentSet() {
        guard let itemID = currentItemID, let reps = currentReps else { return }
        attemptLog(itemID: itemID, reps: reps)
    }

    private func attemptLog(itemID: UUID, reps: Int) {
        var attempt = engine
        do {
            let outcome = try attempt.handleDoubleTap(itemID: itemID, reps: reps)
            try store.saveActiveSession(attempt.session)
            engine = attempt
            saveFailure = nil
            pendingRetry = nil
            play(outcome.haptics)
            refreshPrefill()
        } catch BurlyStoreError.sessionNoLongerInFlight(_, _) {
            resolveSessionNoLongerInFlight()
        } catch {
            saveFailure = String(describing: error)
            pendingRetry = { [weak self] in self?.attemptLog(itemID: itemID, reps: reps) }
        }
    }

    // MARK: - Rest timer (§3 hosting seam)

    var restRemaining: TimeInterval { engine.restRemaining }
    var isRestRunning: Bool { engine.session.restTimer != nil && engine.restRemaining > 0 }
    /// The persisted wall-clock state the banner renders. The banner may
    /// read its dates but never alters this value; RestTimerEngine remains
    /// the only state machine for rest transitions and haptic decisions.
    var restTimer: RestTimerState? { engine.session.restTimer }

    func adjustRest(by delta: TimeInterval) {
        play(engine.adjustRest(by: delta))
        persist()
    }

    func skipRest() {
        engine.skipRest()
        persist()
    }

    /// §2 Always-On: the screen actually woke from the dimmed state --
    /// feeds §3's "repeats once at +5 s if screen never woke." Persists
    /// whenever this actually moved `ActiveSession.restTimer` (m2-03
    /// review finding 5) -- `RestTimerEngine.noteScreenWake` only latches
    /// the *first* wake of a rest (its own doc), so a second call in the
    /// same rest window is correctly a no-op here too, but the first must
    /// not be silently dropped: without this save, a crash before the next
    /// haptic-producing tick loses the fact that the screen ever woke, and
    /// a stale `screenWokeAt` from a *previous* rest could otherwise
    /// wrongly suppress this rest's missed-finish repeat on resume.
    func noteScreenWake() {
        let before = engine.session.restTimer
        engine.noteScreenWake()
        if engine.session.restTimer != before {
            persist()
        }
    }

    /// Driven at 1 Hz by the logging screen's `TimelineView` (§2 Always-On:
    /// "1 Hz `TimelineView`"). `SessionEngine.tick()` is idempotent, so
    /// calling it redundantly is harmless.
    ///
    /// Persists whenever the tick actually moved `ActiveSession.restTimer`
    /// -- **not** whenever it produced a haptic (m2-03 review finding 5).
    /// Those are different questions: a suppressed missed-finish repeat
    /// (the screen woke in time, so `RestTimerEngine.evaluate` latches
    /// `repeatFired = true` but returns no haptic) still changed the
    /// timer's persisted state, and skipping the save on that tick because
    /// haptics happened to be empty is exactly what let a crash replay the
    /// same "missed finish" repeat after a resume that saw the screen wake
    /// in time.
    func tick() {
        let before = engine.session.restTimer
        let firedHaptics = engine.tick()
        play(firedHaptics)
        if engine.session.restTimer != before {
            persist()
        }
    }

    // MARK: - Mid-session edits (§2 ellipsis menu)

    func addSetOnCurrent() {
        guard let id = currentItemID else { return }
        try? engine.addSet(toItem: id)
        persist()
    }

    func removeEmptySetOnCurrent() {
        guard let id = currentItemID else { return }
        try? engine.removeEmptySet(fromItem: id)
        persist()
    }

    func skipCurrentExercise() {
        guard let id = currentItemID else { return }
        try? engine.skipExercise(itemID: id)
        applyCurrentItem(engine.session.unskippedItems.first?.id)
    }

    func moveCurrentUp() {
        guard let id = currentItemID else { return }
        try? engine.moveItemUp(itemID: id)
        persist()
    }

    func moveCurrentDown() {
        guard let id = currentItemID else { return }
        try? engine.moveItemDown(itemID: id)
        persist()
    }

    /// §2 "swap exercise." `nil` clears the picker without swapping.
    func swap(currentItem itemID: UUID, to exerciseID: UUID?) {
        pickerContext = nil
        guard let exerciseID else { return }
        guard let newID = try? engine.swapExercise(itemID: itemID, toExerciseID: exerciseID) else { return }
        applyCurrentItem(newID)
    }

    /// §2 "add exercise" from the catalog picker.
    func addExercise(_ exerciseID: UUID) {
        pickerContext = nil
        guard let newID = try? engine.addExercise(exerciseID: exerciseID) else { return }
        applyCurrentItem(newID)
    }

    /// §2 "add exercise" → "Custom (name later)": creates the `needsNaming`
    /// placeholder and persists it into the watch catalog (`SessionMutator
    /// .addPlaceholderExercise`'s doc: "the caller persists the exercise
    /// into the watch catalog").
    ///
    /// The engine mutation is attempted on a **snapshot** and only folded
    /// into `engine` once catalog persistence (`store.createExercise`)
    /// succeeds (m2-03 review finding 8) -- the previous shape called
    /// `engine.addPlaceholderExercise()` directly, so a failed
    /// `try? store.createExercise` still left the session graph pointing
    /// at an exercise the catalog never got, which then made every
    /// subsequent `saveActiveSession` fail its dangling-reference
    /// preflight with no visible error. A failure here surfaces through
    /// the same `saveFailure` blocking state as an ordinary log-set
    /// failure, with a retry that redoes the whole attempt.
    func addPlaceholderExercise() {
        pickerContext = nil
        attemptAddPlaceholderExercise()
    }

    private func attemptAddPlaceholderExercise() {
        var attempt = engine
        do {
            let result = try attempt.addPlaceholderExercise()
            try store.createExercise(result.exercise)
            engine = attempt
            saveFailure = nil
            pendingRetry = nil
            applyCurrentItem(result.itemID)
        } catch {
            saveFailure = String(describing: error)
            pendingRetry = { [weak self] in self?.attemptAddPlaceholderExercise() }
        }
    }

    // MARK: - Finish (§2)

    func requestEndWorkout() {
        endWorkoutPreview = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: now(), lastPerformance: lastPerformance(for:)
        )
    }

    func keepGoing() {
        endWorkoutPreview = nil
    }

    /// Commits Finish. Guarded by `isFinishing` so a double-tap on the
    /// summary screen's Finish control cannot call `engine.finish()`
    /// twice. `engine.finish()` itself is atomic (`SessionMutator.finish`'s
    /// `requireActive` check runs before any mutation) -- if it throws,
    /// nothing moved and this is a plain, non-recoverable error. Once it
    /// succeeds, though, the in-memory session is `.logged` and there is no
    /// going back (`SessionMutator.finish` refuses a second call), so the
    /// follow-up save is handled by `persistFinish()`, which
    /// `retryFinishSave()` can call again without re-finishing (m2-03
    /// review finding 6).
    func commitFinish() {
        guard !isFinishing, finishedSummary == nil else { return }
        isFinishing = true
        finishSaveError = nil
        do {
            pendingFinishHaptics = try engine.finish()
        } catch {
            finishSaveError = String(describing: error)
            isFinishing = false
            return
        }
        persistFinish()
    }

    /// Retries the save after `engine.finish()` already committed
    /// in-memory. Never calls `engine.finish()` again -- `SessionMutator
    /// .finish` refuses an already-`.logged` session, so a second call
    /// here would throw `.sessionNotActive` even though the *store* write
    /// is what actually failed (m2-03 review finding 6).
    func retryFinishSave() {
        guard isFinishing, finishedSummary == nil else { return }
        persistFinish()
    }

    private func persistFinish() {
        do {
            try store.saveActiveSession(engine.session)
            finishSaveError = nil
            play(pendingFinishHaptics)
            pendingFinishHaptics = []
            finishedSummary = SessionSummaryBuilder.summarize(
                engine.session, referenceDate: now(), lastPerformance: lastPerformance(for:)
            )
        } catch BurlyStoreError.sessionNoLongerInFlight(_, _) {
            // m2-06 review finding 3.1: the store already moved this
            // session out of `.active` through some other legitimate
            // writer -- retrying this exact save can never succeed
            // (`saveActiveSession` refuses it every time), so the ordinary
            // "stays true, offer Retry" contract above would wedge
            // `isFinishing` forever with Keep going/Discard disabled and
            // no working forward path. Resolve to the session's real
            // terminal state instead, which also clears `isFinishing`.
            resolveSessionNoLongerInFlight()
        } catch {
            // `isFinishing` stays true: the engine already committed
            // `.logged` in memory, so the summary screen must keep offering
            // retry, never "Keep going" back into a logging screen whose
            // engine now rejects every further mutation.
            finishSaveError = String(describing: error)
        }
    }

    // MARK: - Discard (§2, destructive, double-confirm)

    func requestDiscard() { isShowingDiscardStepOne = true }

    func confirmDiscardStepOne() {
        isShowingDiscardStepOne = false
        isShowingDiscardStepTwo = true
    }

    /// `didDiscard` is set **only** after a successful deletion (m2-03
    /// review finding 9) -- the previous `try?` set it regardless, which
    /// dismissed the screen and told the lifter the destructive action
    /// completed while the session was, in fact, still journaled and would
    /// go on to block every future Start. A failed deletion routes through
    /// the same `saveFailure` blocking state as a failed log-set or
    /// placeholder creation (`retrySave()` retries it) -- Discard is
    /// reachable both from the ellipsis menu directly and from the summary
    /// screen, so its failure state has to be visible from either place,
    /// not embedded in a summary view that may not even be on screen.
    func confirmDiscardStepTwo() {
        isShowingDiscardStepTwo = false
        performDiscard()
    }

    private func performDiscard() {
        do {
            _ = try store.deleteSession(id: engine.session.id)
            saveFailure = nil
            pendingRetry = nil
            didDiscard = true
        } catch {
            saveFailure = String(describing: error)
            pendingRetry = { [weak self] in self?.performDiscard() }
        }
    }

    func cancelDiscard() {
        isShowingDiscardStepOne = false
        isShowingDiscardStepTwo = false
    }

    // MARK: - Save failure recovery (m2-03 review findings 7-8)

    /// Redoes exactly the attempt that produced `saveFailure` -- either a
    /// log-set or a placeholder-exercise creation, whichever failed. Both
    /// retry on a **fresh** snapshot of the current `engine`, so a retry
    /// after some *other* mutation succeeded in between still applies
    /// cleanly.
    func retrySave() {
        guard saveFailure != nil, let retry = pendingRetry else { return }
        pendingRetry = nil
        retry()
    }

    // MARK: - Internals

    /// The generic mutation-save path: attempts `store.saveActiveSession`
    /// for a mutation that has *already* been applied to `engine` (adding a
    /// set slot, reordering, paging away, adjusting rest -- structural
    /// edits whose in-memory shape is not itself something the UI could
    /// mistake for "logged," unlike a set). On failure this still blocks
    /// the logging screen with the same `saveFailure` state logging and
    /// placeholder creation use; the retry simply re-attempts the save,
    /// since the mutation that produced the current `engine.session` is
    /// already correct -- only the store write needs to happen again.
    private func persist() {
        do {
            try store.saveActiveSession(engine.session)
            saveFailure = nil
            pendingRetry = nil
        } catch BurlyStoreError.sessionNoLongerInFlight(_, _) {
            resolveSessionNoLongerInFlight()
        } catch {
            saveFailure = String(describing: error)
            pendingRetry = { [weak self] in self?.persist() }
        }
    }

    /// m2-06 review finding 3.1: `.sessionNoLongerInFlight` means the
    /// **store**, not this view, already moved the session out of
    /// `.active` -- some other legitimate writer (a §6 phone edit, a
    /// future sync apply) got there first while this view was still
    /// attached to it. That is a terminal state transition, not a
    /// transient save failure: this view's `engine.session` is stale
    /// active state that `saveActiveSession` will refuse forever, so
    /// installing the ordinary `pendingRetry`/`finishSaveError` closures
    /// the other catch branches use would resubmit that same stale state
    /// on every retry and wedge permanently -- worse than an ordinary
    /// transient failure, because there, retrying eventually succeeds.
    ///
    /// Resolves by re-reading the session's *real* stored state and
    /// routing there directly, exactly the way a normal Finish or Discard
    /// would have looked from the outside:
    ///
    /// - Still stored (the common case -- some other writer finished it):
    ///   renders through the same `finishedSummary` acknowledgement Finish
    ///   itself produces. `plans: [:]` is safe here -- `SessionSummaryBuilder
    ///   .summarize` never reads `ActiveSession.plans`/`.restTimer`, only
    ///   `session.items`/`.startedAt`/`.endedAt` (see that type's doc).
    /// - No longer stored at all (a §6 delete): dismisses through
    ///   `didDiscard`, same as an ordinary successful Discard.
    ///
    /// Clears every blocking/retry flag this view can be in, including
    /// `isFinishing` -- the specific gap m2-06 review finding 3.1 named:
    /// without this, a Finish that hit this condition left `isFinishing ==
    /// true` forever, disabling Keep going and Discard while Retry could
    /// never succeed.
    private func resolveSessionNoLongerInFlight() {
        isFinishing = false
        finishSaveError = nil
        saveFailure = nil
        pendingRetry = nil
        pendingFinishHaptics = []
        endWorkoutPreview = nil
        do {
            if let stored = try store.session(id: engine.session.id) {
                finishedSummary = SessionSummaryBuilder.summarize(
                    ActiveSession(session: stored, plans: [:]),
                    referenceDate: now(),
                    lastPerformance: lastPerformance(for:)
                )
            } else {
                didDiscard = true
            }
        } catch {
            // The re-read itself failed -- an honest blocking error rather
            // than silently claiming resolution that may not have
            // happened. Retrying redoes this same resolution, not the
            // original (already-doomed) mutation.
            saveFailure = String(describing: error)
            pendingRetry = { [weak self] in self?.resolveSessionNoLongerInFlight() }
        }
    }

    private func play(_ events: [HapticEvent]) {
        guard !events.isEmpty else { return }
        haptics.play(events)
    }

    /// `nil` on lookup failure or absence alike -- both render as an empty
    /// ghost, never a crash (§2 acceptance #5).
    private func lastPerformance(for exerciseID: UUID?) -> ExerciseLastPerformanceData? {
        guard let exerciseID else { return nil }
        if let cached = digestCache[exerciseID] { return cached }
        let value = (try? store.lastPerformance(exerciseID: exerciseID)) ?? nil
        digestCache[exerciseID] = value
        return value
    }
}
