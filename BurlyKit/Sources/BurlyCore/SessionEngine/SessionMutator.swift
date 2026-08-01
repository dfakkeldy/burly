// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionMutationError, SessionMutator
//
// Spec §2 "Mid-session edits", as pure functions over `ActiveSession`:
// add set / remove empty set, skip exercise, swap exercise, add exercise
// (including the `needsNaming` placeholder), reorder, plus the log-set
// write itself.
//
// Every operation re-establishes ActiveSession's invariants I1–I5 (see
// ActiveSession.swift). Three of them shape the API directly:
//
// - **Only empty slots can be removed.** §2 says "remove empty set"; I4
//   makes that mechanical — a slot is removable iff
//   `plannedSetCount > sets.count`. There is no code path that deletes a
//   `SetRecordData`, so "preserves already-logged set data" is not a
//   property that has to be re-checked at each call site: it is a property
//   of the surface.
// - **Ordering is dense.** Nothing here can leave a gap or a duplicate in
//   `order`; every structural change renumbers.
// - **A logged session is closed.** After `finish`, the session is
//   `.logged` and immutable on the watch (§2 Finish, §6 gives the phone
//   the editor). Every mutator rejects it.
//
// Imports Foundation for `UUID`/`TimeInterval` only.
import Foundation

/// Why a §2 mid-session edit could not be applied. Each case is a state
/// the watch UI should have disabled the control for; they exist so the
/// engine fails loudly in tests instead of silently corrupting a session.
public enum SessionMutationError: Error, Equatable, Hashable {
    /// The session is `.logged`; the watch does not edit finished sessions.
    case sessionNotActive

    case unknownItem(UUID)

    /// "Remove empty set" with every slot filled — removing would destroy
    /// logged data.
    case noEmptySetSlot(itemID: UUID)

    /// Removing the last slot would leave an exercise with no sets to log;
    /// that is "skip exercise", not "remove set".
    case cannotRemoveLastSetSlot(itemID: UUID)

    /// Move up from the top / move down from the bottom.
    case itemAlreadyAtEdge(itemID: UUID)

    case indexOutOfRange(Int)

    /// A set with no reps is not a set.
    case invalidReps(Int)
}

public enum SessionMutator {

    // MARK: - Set slots

    /// §2 "add set": one more empty slot on this exercise.
    public static func addSet(
        toItem itemID: UUID,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard var plan = session.plans[itemID], session.index(ofItem: itemID) != nil else {
            throw SessionMutationError.unknownItem(itemID)
        }
        plan.plannedSetCount += 1
        session.plans[itemID] = plan
    }

    /// §2 "remove empty set" — and only an empty one. Removes the last
    /// slot, which by I4 is guaranteed to be the unlogged one.
    public static func removeEmptySet(
        fromItem itemID: UUID,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID), var plan = session.plans[itemID] else {
            throw SessionMutationError.unknownItem(itemID)
        }
        let logged = session.session.items[index].sets.count
        guard plan.plannedSetCount > logged else {
            throw SessionMutationError.noEmptySetSlot(itemID: itemID)
        }
        guard plan.plannedSetCount > 1 else {
            throw SessionMutationError.cannotRemoveLastSetSlot(itemID: itemID)
        }
        plan.plannedSetCount -= 1
        session.plans[itemID] = plan
    }

    // MARK: - Logging

    /// Writes a `SetRecord` (§2 Logging: "writes SetRecord immediately").
    ///
    /// `completedAt` comes from the injected clock. The set is appended
    /// with the next dense order (I2), and the plan grows to match if the
    /// lifter logged past the planned count (I4) — an extra set is data,
    /// and data always wins over scaffolding.
    @discardableResult
    public static func logSet(
        itemID: UUID,
        weight: Weight,
        reps: Int,
        isWarmup: Bool = false,
        in session: inout ActiveSession,
        clock: any WallClock,
        makeID: () -> UUID = UUID.init
    ) throws -> SetRecordData {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID), var plan = session.plans[itemID] else {
            throw SessionMutationError.unknownItem(itemID)
        }
        guard reps > 0 else {
            throw SessionMutationError.invalidReps(reps)
        }

        let record = SetRecordData(
            id: makeID(),
            order: session.session.items[index].sets.count,
            weight: weight,
            reps: reps,
            isWarmup: isWarmup,
            completedAt: clock.now
        )
        session.session.items[index].sets.append(record)

        plan.plannedSetCount = max(plan.plannedSetCount, session.session.items[index].sets.count)
        session.plans[itemID] = plan

        return record
    }

    // MARK: - Exercise-level edits

    /// §2 "skip exercise". Routing only: the item keeps its place, its id,
    /// and every set already logged against it.
    public static func skipExercise(
        itemID: UUID,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard var plan = session.plans[itemID], session.index(ofItem: itemID) != nil else {
            throw SessionMutationError.unknownItem(itemID)
        }
        plan.isSkipped = true
        session.plans[itemID] = plan
    }

    /// §2 "swap exercise" (catalog picker).
    ///
    /// The swap happens **in place**: same item id, same position, same
    /// plan, same sets. §2's acceptance criterion is that mutations
    /// "preserve set data", and the lifter who swaps mid-exercise did the
    /// work already logged — dropping it to keep the exercise attribution
    /// tidy would delete real reps, which is the worse failure. (The phone
    /// can re-attribute later, §6.)
    public static func swapExercise(
        itemID: UUID,
        toExerciseID exerciseID: UUID?,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID) else {
            throw SessionMutationError.unknownItem(itemID)
        }
        session.session.items[index].exerciseID = exerciseID
    }

    /// §2 "add exercise". Appends by default; `at:` inserts and renumbers.
    /// Returns the new item's id.
    @discardableResult
    public static func addExercise(
        exerciseID: UUID?,
        plannedSetCount: Int = 3,
        restOverride: TimeInterval? = nil,
        at index: Int? = nil,
        in session: inout ActiveSession,
        makeID: () -> UUID = UUID.init
    ) throws -> UUID {
        try requireActive(session)
        let insertionIndex = index ?? session.session.items.count
        guard insertionIndex >= 0, insertionIndex <= session.session.items.count else {
            throw SessionMutationError.indexOutOfRange(insertionIndex)
        }

        let itemID = makeID()
        session.session.items.insert(
            SessionItemData(id: itemID, exerciseID: exerciseID, order: insertionIndex, sets: []),
            at: insertionIndex
        )
        session.plans[itemID] = ItemPlan(
            plannedSetCount: max(1, plannedSetCount),
            restOverride: restOverride,
            isSkipped: false
        )
        renumberItems(&session)
        return itemID
    }

    /// The picker's "Custom (name later)" row (§2): creates a placeholder
    /// `ExerciseData` with `needsNaming` set, adds an item for it, and
    /// hands both back. The caller persists the exercise into the watch
    /// catalog; the session payload embeds it on sync so the phone can
    /// prompt for a real name (§5 placeholder merge, §6 naming queue).
    @discardableResult
    public static func addPlaceholderExercise(
        plannedSetCount: Int = 3,
        restOverride: TimeInterval? = nil,
        at index: Int? = nil,
        in session: inout ActiveSession,
        makeID: () -> UUID = UUID.init
    ) throws -> (itemID: UUID, exercise: ExerciseData) {
        let exercise = ExerciseData(
            id: makeID(),
            name: placeholderExerciseName,
            // No tags: guessing muscle groups for an unnamed exercise would
            // put invented data in the muscle-split stat (§7). The phone
            // collects them with the name.
            muscleGroups: [],
            origin: .custom,
            needsNaming: true
        )
        let itemID = try addExercise(
            exerciseID: exercise.id,
            plannedSetCount: plannedSetCount,
            restOverride: restOverride,
            at: index,
            in: &session,
            makeID: makeID
        )
        return (itemID, exercise)
    }

    /// The name a watch-created placeholder carries until the phone renames
    /// it. Public so the watch and phone render the same string.
    public static let placeholderExerciseName = "Custom exercise"

    // MARK: - Reordering

    /// §2 "reorder (move up/down)".
    public static func moveItemUp(
        itemID: UUID,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID) else {
            throw SessionMutationError.unknownItem(itemID)
        }
        guard index > 0 else {
            throw SessionMutationError.itemAlreadyAtEdge(itemID: itemID)
        }
        try move(itemID: itemID, to: index - 1, in: &session)
    }

    public static func moveItemDown(
        itemID: UUID,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID) else {
            throw SessionMutationError.unknownItem(itemID)
        }
        guard index < session.session.items.count - 1 else {
            throw SessionMutationError.itemAlreadyAtEdge(itemID: itemID)
        }
        try move(itemID: itemID, to: index + 1, in: &session)
    }

    /// Moves an item to an absolute index and renumbers. Sets travel with
    /// their item; nothing about them changes (I5).
    public static func move(
        itemID: UUID,
        to destination: Int,
        in session: inout ActiveSession
    ) throws {
        try requireActive(session)
        guard let index = session.index(ofItem: itemID) else {
            throw SessionMutationError.unknownItem(itemID)
        }
        guard destination >= 0, destination < session.session.items.count else {
            throw SessionMutationError.indexOutOfRange(destination)
        }
        guard destination != index else { return }

        let item = session.session.items.remove(at: index)
        session.session.items.insert(item, at: destination)
        renumberItems(&session)
    }

    public static func canMoveUp(itemID: UUID, in session: ActiveSession) -> Bool {
        (session.index(ofItem: itemID) ?? 0) > 0
    }

    public static func canMoveDown(itemID: UUID, in session: ActiveSession) -> Bool {
        guard let index = session.index(ofItem: itemID) else { return false }
        return index < session.session.items.count - 1
    }

    // MARK: - Finish

    /// §2 Finish: the session becomes `.logged` (immutable on the watch),
    /// gets its end timestamp, and drops any running rest timer.
    public static func finish(
        _ session: inout ActiveSession,
        clock: any WallClock
    ) throws {
        try requireActive(session)
        session.session.state = .logged
        session.session.endedAt = clock.now
        session.restTimer = nil
    }

    // MARK: - Internals

    private static func renumberItems(_ session: inout ActiveSession) {
        for index in session.session.items.indices {
            session.session.items[index].order = index
        }
    }

    private static func requireActive(_ session: ActiveSession) throws {
        guard session.isActive else {
            throw SessionMutationError.sessionNotActive
        }
    }
}
