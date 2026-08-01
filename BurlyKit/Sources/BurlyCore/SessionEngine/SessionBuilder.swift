// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionBuilder
//
// Spec §2 Start: "Start creates the Session as a mutable copy of the
// routine (architecture: routine = template, session = mutable copy)".
//
// Copy, not reference. Every session item gets a **new** id: the routine
// item is a template row that the user may edit or delete tomorrow, while
// the session item is a thing that happened. Only the exercise is shared,
// and only by UUID (architecture doc: cross-device references are by UUID).
// The routine's own identity survives as `routineID` plus the denormalized
// `routineName`, which is what keeps a session's provenance readable after
// the routine is archived (§1).
//
// The set slots are `ItemPlan.plannedSetCount`, not empty `SetRecord`s —
// see ActiveSession.swift for why a planned-but-unlogged set must never
// exist as a record.
//
// Imports Foundation for `UUID`/`Date` only.
import Foundation

public enum SessionBuilder {
    /// Builds the in-flight session for "Start" on a routine row (§2).
    ///
    /// - Parameters:
    ///   - routine: the template. Its items are copied in `order`, and the
    ///     copy is renumbered densely from 0 even if the template's order
    ///     values are sparse or duplicated.
    ///   - clock: supplies `startedAt`.
    ///   - makeID: id source, injectable so tests can be deterministic.
    public static func session(
        from routine: RoutineData,
        clock: any WallClock,
        makeID: () -> UUID = UUID.init
    ) -> ActiveSession {
        let ordered = routine.items
            .enumerated()
            .sorted { lhs, rhs in
                // Stable: ties fall back to the template's own array order.
                lhs.element.order == rhs.element.order
                    ? lhs.offset < rhs.offset
                    : lhs.element.order < rhs.element.order
            }
            .map(\.element)

        var items: [SessionItemData] = []
        var plans: [UUID: ItemPlan] = [:]
        items.reserveCapacity(ordered.count)

        for (index, routineItem) in ordered.enumerated() {
            let itemID = makeID()
            items.append(
                SessionItemData(
                    id: itemID,
                    exerciseID: routineItem.exerciseID,
                    order: index,
                    sets: []
                )
            )
            plans[itemID] = ItemPlan(
                // Invariant I4: at least one slot, whatever the template
                // says. A 0-set routine item would otherwise produce an
                // exercise page with nothing to log.
                plannedSetCount: max(1, routineItem.defaultSetCount),
                restOverride: routineItem.restOverride,
                isSkipped: false
            )
        }

        let session = SessionData(
            id: makeID(),
            routineID: routine.id,
            routineName: routine.name,
            startedAt: clock.now,
            endedAt: nil,
            state: .active,
            revision: 1,
            healthKitWorkoutID: nil,
            origin: .live,
            items: items,
            notes: nil
        )

        return ActiveSession(session: session, plans: plans, restTimer: nil)
    }

    /// "Empty session" at the end of the watch's routine list (§2 Start).
    /// No routine, no items — exercises are added from the picker
    /// mid-session (`SessionMutator.addExercise`).
    public static func emptySession(
        clock: any WallClock,
        makeID: () -> UUID = UUID.init
    ) -> ActiveSession {
        ActiveSession(
            session: SessionData(
                id: makeID(),
                routineID: nil,
                routineName: nil,
                startedAt: clock.now,
                state: .active,
                revision: 1,
                origin: .live,
                items: []
            ),
            plans: [:],
            restTimer: nil
        )
    }
}
