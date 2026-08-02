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
import Foundation
import SwiftUI
import Observation
import BurlyCore
import BurlyPersistence

/// Where a swap/add picker should write its result back to.
enum ExercisePickerContext: Identifiable, Equatable {
    /// §2 ellipsis "swap exercise" on this item.
    case swap(itemID: UUID)
    /// §2 ellipsis "add exercise", appended to the end.
    case add

    var id: String {
        switch self {
        case .swap(let itemID): "swap-\(itemID.uuidString)"
        case .add: "add"
        }
    }
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
    private(set) var currentReps: Int = 8

    /// §2 "End workout": the pre-commit summary preview. Non-nil means the
    /// summary screen is showing; nothing in `engine` has changed yet.
    private(set) var endWorkoutPreview: SessionSummary?

    /// Set once Finish has actually committed. The summary screen switches
    /// from Finish/Keep going/Discard to a plain "Saved" acknowledgement.
    private(set) var finishedSummary: SessionSummary?

    /// True once a discard has been committed -- the host view dismisses.
    private(set) var didDiscard = false

    private(set) var isFinishing = false
    private(set) var errorMessage: String?

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

    init(
        engine: SessionEngine,
        store: BurlyStore,
        haptics: HapticPlaying = HapticPlayer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.store = store
        self.haptics = haptics
        self.now = now
        self.currentItemID = engine.session.unskippedItems.first?.id
        refreshPrefill()
        // §2 Start: "Start creates the Session ... navigates to the logging
        // screen." BurlyStore.swift: "saveActiveSession ... creates the
        // session if it isn't stored yet, so §2 Start is the same one call
        // as every mutation after it." This is that call.
        persist()
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
        applyCurrentItem(id, firesPageAwayHaptic: true)
    }

    /// Used after a mutation (swap/add/skip) that may leave `currentItemID`
    /// numerically unchanged but semantically different (a swap in place
    /// changes the exercise under the same item id) -- always refreshes,
    /// never gated on "did the id change."
    private func applyCurrentItem(_ id: UUID?, firesPageAwayHaptic: Bool) {
        if firesPageAwayHaptic {
            play(engine.pageAway())
        }
        currentItemID = id
        refreshPrefill()
        persist()
    }

    /// Recomputes the scratch reps and seeds the weight control from the
    /// §2 prefill ladder for whatever `currentItemID` is now. Always sets
    /// the weight explicitly -- `engine.weightEdit` is one value shared by
    /// the whole session, not one per item, so leaving it untouched would
    /// carry the previous exercise's weight onto this one.
    private func refreshPrefill() {
        guard let item = currentItem else {
            engine.prefillWeight(.bodyweight)
            currentReps = 8
            return
        }
        let prefill = engine.prefill(forItem: item.id, lastPerformance: lastPerformance(for: item.exerciseID))
        engine.prefillWeight(prefill.weight ?? .bodyweight)
        currentReps = prefill.reps ?? 8
    }

    // MARK: - Reps (scratch, no lock -- §2 only guards weight)

    func incrementReps() { currentReps += 1 }

    func decrementReps() { currentReps = Swift.max(1, currentReps - 1) }

    func adjustReps(bySteps steps: Int) {
        guard steps != 0 else { return }
        currentReps = Swift.max(1, currentReps + steps)
    }

    // MARK: - Guarded weight edit (§2)

    func armWeight() { play(engine.handleWeightEdit(.longPressArm).haptics) }

    func adjustWeight(bySteps steps: Int) { play(engine.handleWeightEdit(.adjust(steps: steps)).haptics) }

    // MARK: - Logging (§2 primary action / Double Tap)

    /// The logging screen's one "Log set" control calls this whether it
    /// was tapped on screen or triggered by the watchOS Double Tap
    /// gesture (`.handGestureShortcut(.primaryAction)`, wired in
    /// `LoggingScreenView`) -- both are, per spec, "the primary action ...
    /// with current values," so there is exactly one call site and it can
    /// never accidentally arm the weight control (`SessionEngine
    /// .handleDoubleTap`'s own doc: "Callers never wire `logsSet`
    /// themselves").
    func logCurrentSet() {
        guard let itemID = currentItemID else { return }
        do {
            let outcome = try engine.handleDoubleTap(itemID: itemID, reps: currentReps)
            play(outcome.haptics)
            refreshPrefill()
            persist()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Rest timer (§3 hosting seam; the timer UI itself is m2-05)

    var restRemaining: TimeInterval { engine.restRemaining }
    var isRestRunning: Bool { engine.session.restTimer != nil && engine.restRemaining > 0 }

    func adjustRest(by delta: TimeInterval) {
        play(engine.adjustRest(by: delta))
        persist()
    }

    func skipRest() {
        engine.skipRest()
        persist()
    }

    func noteScreenWake() {
        engine.noteScreenWake()
    }

    /// Driven at 1 Hz by the logging screen's `TimelineView` (§2 Always-On:
    /// "1 Hz `TimelineView`"). `SessionEngine.tick()` is idempotent, so
    /// calling it redundantly is harmless; only persisted when it actually
    /// moved a latch (haptics non-empty) -- ticks that produce nothing
    /// leave `ActiveSession.restTimer` byte-identical, and a SwiftData
    /// write every second the rest timer runs is not what "after every
    /// mutation" is protecting against.
    func tick() {
        let firedHaptics = engine.tick()
        guard !firedHaptics.isEmpty else { return }
        play(firedHaptics)
        persist()
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
        applyCurrentItem(engine.session.unskippedItems.first?.id, firesPageAwayHaptic: false)
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
        applyCurrentItem(newID, firesPageAwayHaptic: false)
    }

    /// §2 "add exercise" from the catalog picker.
    func addExercise(_ exerciseID: UUID) {
        pickerContext = nil
        guard let newID = try? engine.addExercise(exerciseID: exerciseID) else { return }
        applyCurrentItem(newID, firesPageAwayHaptic: false)
    }

    /// §2 "add exercise" → "Custom (name later)": creates the `needsNaming`
    /// placeholder and persists it into the watch catalog (`SessionMutator
    /// .addPlaceholderExercise`'s doc: "the caller persists the exercise
    /// into the watch catalog").
    func addPlaceholderExercise() {
        pickerContext = nil
        guard let result = try? engine.addPlaceholderExercise() else { return }
        try? store.createExercise(result.exercise)
        applyCurrentItem(result.itemID, firesPageAwayHaptic: false)
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
    /// summary screen's Finish control cannot fire `saveActiveSession`
    /// twice -- the second call after a successful Finish would throw
    /// `.sessionNoLongerInFlight` (BurlyStore.swift: "Finish is one-way").
    func commitFinish() {
        guard !isFinishing, finishedSummary == nil else { return }
        isFinishing = true
        do {
            let closingHaptics = try engine.finish()
            try store.saveActiveSession(engine.session)
            play(closingHaptics)
            finishedSummary = SessionSummaryBuilder.summarize(
                engine.session, referenceDate: now(), lastPerformance: lastPerformance(for:)
            )
        } catch {
            errorMessage = String(describing: error)
            isFinishing = false
        }
    }

    // MARK: - Discard (§2, destructive, double-confirm)

    func requestDiscard() { isShowingDiscardStepOne = true }

    func confirmDiscardStepOne() {
        isShowingDiscardStepOne = false
        isShowingDiscardStepTwo = true
    }

    func confirmDiscardStepTwo() {
        isShowingDiscardStepTwo = false
        _ = try? store.deleteSession(id: engine.session.id)
        didDiscard = true
    }

    func cancelDiscard() {
        isShowingDiscardStepOne = false
        isShowingDiscardStepTwo = false
    }

    // MARK: - Internals

    private func persist() {
        do {
            try store.saveActiveSession(engine.session)
        } catch {
            errorMessage = String(describing: error)
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
