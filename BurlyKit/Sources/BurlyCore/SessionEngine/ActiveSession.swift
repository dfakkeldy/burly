// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ActiveSession, ItemPlan
//
// The watch's in-flight working record for spec §2: a `SessionData` (the
// persisted §1 shape, authoritative for everything that is ever stored or
// synced) plus the small amount of *plan* state that only exists while a
// session is being performed.
//
// ## Why a wrapper rather than new fields on SessionData
//
// §1 is FROZEN. `SessionItem` has no "planned set count", no
// `restOverride`, and no "skipped" flag — and it should not: none of the
// three is history. A session that ended with 2 of 3 planned sets logged
// records two sets, full stop; the third slot was scaffolding on a screen.
// Adding those fields to the §1 entities would be a frozen-section change
// and would persist scaffolding as if it were data. So the scaffolding
// lives here, alongside the session, for exactly as long as the session is
// active. `session` alone is what BurlyPersistence stores and BurlySync
// ships (§5).
//
// `restTimer` is carried here for the same reason and one more: §3
// requires the timer state to be "part of the active session record" so it
// survives crash/resume. It is a pure value (a stored `endDate` plus which
// haptics already fired), so the whole `ActiveSession` is `Codable` and can
// be journaled as one blob.
//
// ## Invariants
//
// Every operation in `SessionMutator` preserves all of these; the
// property-style tests generate random mutation sequences and assert
// `invariantViolations().isEmpty` after each step.
//
// - **I1 dense item order** — `session.items[i].order == i`, for all i.
// - **I2 dense set order** — within each item, `sets[j].order == j`.
// - **I3 plan bijection** — `plans.keys` is exactly the set of item ids:
//   every item has a plan, no plan outlives its item.
// - **I4 plan floor** — `plannedSetCount >= max(1, sets.count)`: there is
//   always at least one slot, and the plan never claims fewer sets than
//   were actually logged. (This is what makes "remove *empty* set only"
//   expressible: an empty slot exists iff `plannedSetCount > sets.count`.)
// - **I5 logged sets are immutable** — no mutation ever edits, reorders,
//   or drops an existing `SetRecordData`. Watch-side, a logged set is
//   history; §6 gives the phone the set-level editor, not the watch.
//
// Imports Foundation for `UUID` and `TimeInterval` only.
import Foundation

/// The scaffolding for one exercise in an in-flight session: how many set
/// slots the screen should show, which rest duration this exercise
/// overrides to, and whether the lifter skipped it.
public struct ItemPlan: Sendable, Equatable, Hashable, Codable {
    /// Number of set slots on the logging screen — the "of 3" in
    /// "Set 2 of 3" (§2 header). Seeded from `RoutineItem.defaultSetCount`
    /// and moved by add set / remove empty set. Never below the number of
    /// sets actually logged (I4).
    public var plannedSetCount: Int

    /// This exercise's rest override (§1 `RoutineItem.restOverride`,
    /// copied at start); first term in §3's resolution order.
    public var restOverride: TimeInterval?

    /// The lifter skipped this exercise mid-session (§2 ellipsis menu).
    /// The item and any sets already logged against it stay exactly where
    /// they are — skipping is a routing decision for the pager, never a
    /// deletion.
    public var isSkipped: Bool

    public init(
        plannedSetCount: Int,
        restOverride: TimeInterval? = nil,
        isSkipped: Bool = false
    ) {
        self.plannedSetCount = plannedSetCount
        self.restOverride = restOverride
        self.isSkipped = isSkipped
    }
}

/// A session being performed on the watch: the persisted session plus its
/// in-flight scaffolding.
///
/// Mutate through `SessionMutator` (and `SessionEngine`), which is where
/// the invariants above are maintained. The stored properties are `var`
/// rather than `private(set)` because `SessionData` is itself a mutable
/// value type — hiding them here would buy nothing real — but any direct
/// mutation is on the caller to keep well-formed.
public struct ActiveSession: Sendable, Equatable, Codable, Identifiable {
    /// The §1 session. Authoritative for everything persisted or synced.
    public var session: SessionData

    /// Plan scaffolding, keyed by `SessionItemData.id` (I3).
    public var plans: [UUID: ItemPlan]

    /// The §3 rest timer, `nil` when no rest is running. Part of this
    /// record so it survives crash/resume.
    public var restTimer: RestTimerState?

    public var id: UUID { session.id }

    public init(
        session: SessionData,
        plans: [UUID: ItemPlan],
        restTimer: RestTimerState? = nil
    ) {
        self.session = session
        self.plans = plans
        self.restTimer = restTimer
    }

    // MARK: - Reads

    public var items: [SessionItemData] { session.items }

    public var isActive: Bool { session.state == .active }

    public func index(ofItem itemID: UUID) -> Int? {
        session.items.firstIndex { $0.id == itemID }
    }

    public func item(_ itemID: UUID) -> SessionItemData? {
        index(ofItem: itemID).map { session.items[$0] }
    }

    public func plan(_ itemID: UUID) -> ItemPlan? {
        plans[itemID]
    }

    /// Number of set slots to render for an item, 0 if unknown.
    public func plannedSetCount(_ itemID: UUID) -> Int {
        plans[itemID]?.plannedSetCount ?? 0
    }

    /// Sets logged so far against an item.
    public func loggedSetCount(_ itemID: UUID) -> Int {
        item(itemID)?.sets.count ?? 0
    }

    /// True when an item has at least one slot with nothing logged in it —
    /// the precondition for "remove empty set" (§2).
    public func hasEmptySetSlot(_ itemID: UUID) -> Bool {
        plannedSetCount(itemID) > loggedSetCount(itemID)
    }

    /// Every set logged in the session, in item then set order. Used by
    /// the invariant tests to prove set data survives every mutation (I5).
    public var allSets: [SetRecordData] {
        session.items.flatMap(\.sets)
    }

    /// Items the pager should route through: everything not skipped, in
    /// order (§2, skip is a routing decision).
    public var unskippedItems: [SessionItemData] {
        session.items.filter { plans[$0.id]?.isSkipped != true }
    }

    // MARK: - Invariants

    /// A human-readable list of invariant violations; empty means
    /// well-formed. Tests assert emptiness after every mutation.
    public func invariantViolations() -> [String] {
        var violations: [String] = []

        for (index, item) in session.items.enumerated() {
            if item.order != index {
                violations.append("I1: item at index \(index) has order \(item.order)")
            }
            for (setIndex, set) in item.sets.enumerated() where set.order != setIndex {
                violations.append(
                    "I2: set at index \(setIndex) of item \(index) has order \(set.order)"
                )
            }
            guard let plan = plans[item.id] else {
                violations.append("I3: item \(item.id) has no plan")
                continue
            }
            if plan.plannedSetCount < max(1, item.sets.count) {
                violations.append(
                    "I4: item \(item.id) plans \(plan.plannedSetCount) sets but logged \(item.sets.count)"
                )
            }
        }

        let itemIDs = Set(session.items.map(\.id))
        for planID in plans.keys where !itemIDs.contains(planID) {
            violations.append("I3: orphan plan for \(planID)")
        }

        if Set(session.items.map(\.id)).count != session.items.count {
            violations.append("I3: duplicate item ids")
        }

        return violations
    }

    public var isWellFormed: Bool { invariantViolations().isEmpty }
}
