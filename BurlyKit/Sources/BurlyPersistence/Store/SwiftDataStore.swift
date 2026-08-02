// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore — the SwiftData implementation of `BurlyStore`
// (architecture doc option A, Dan's pick 2026-07-31).
//
// Autosave is off and every mutating method saves before returning, through
// the one `commit()` helper at the bottom of the file — which rolls the
// context back if the save fails, so a failed call leaves nothing staged for
// a later unrelated save to commit (m1-06 review round E). The data is tiny
// (§ architecture: ~40–50k rows for a decade of lifting) and §2 requires a
// logged set to be durable at tap time; predictable saves are worth more
// here than batching.

import Foundation
import SwiftData
import BurlyCore

public final class SwiftDataStore: BurlyStore {

    /// Not Sendable, and neither is this class — see BurlyStore's threading
    /// note. One store, one isolation domain.
    private let context: ModelContext

    /// Which device this store belongs to (§1 store shape: phone vs. watch
    /// content differ). Inferred from the container's configuration name
    /// rather than threaded through as a separate stored argument, so every
    /// construction path — `.phone(at:)`, `.watch(at:)`, the `kind:`
    /// convenience initializer, or the internal `container:` initializer
    /// tests reach via `@testable` — reports the same, correct kind without
    /// callers having to repeat it. `nil` only when the container's
    /// configuration name doesn't match a known `BurlyStoreKind` (e.g. a
    /// container assembled by hand, bypassing `BurlyContainer`); treated as
    /// "not watch" by kind-gated operations.
    private let kind: BurlyStoreKind?

    /// The store's own time source, for the metadata the store owns rather
    /// than the caller: `Routine.updatedAt` on the local-authoring paths
    /// (`createRoutine`, `updateRoutine`) and the journal's sort key.
    ///
    /// Injected rather than reading `Date()` inline so the ownership rule
    /// is testable as a rule — "the stored timestamp is *the store's* now,
    /// never the DTO's" is only provable against a clock the test controls.
    /// It is deliberately *not* consulted by `applyRoutineSnapshot`, which
    /// replicates someone else's authored timestamp.
    private let clock: any WallClock

    /// Internal — see BurlyContainer.swift's boundary doc: `ModelContainer`
    /// must never appear in a public signature of this module. Construct a
    /// store publicly through `.phone(at:)` / `.watch(at:)` /
    /// `init(kind:at:)` instead.
    init(container: ModelContainer, clock: any WallClock = SystemWallClock()) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        let configuredName = container.configurations.first?.name
        self.kind = BurlyStoreKind.allCases.first { $0.storeName == configuredName }
        self.clock = clock
    }

    public convenience init(
        kind: BurlyStoreKind,
        at location: BurlyStoreLocation = .applicationDefault,
        clock: any WallClock = SystemWallClock()
    ) throws {
        self.init(container: try BurlyContainer.make(kind, at: location), clock: clock)
    }

    /// Phone store: full history (§1 store shape). The public counterpart
    /// of the old (now-internal) `BurlyContainer.phone` — this and
    /// `.watch(at:)` are the two named, device-shaped entry points; use
    /// `init(kind:at:)` directly only when the kind is a runtime value.
    public static func phone(
        at location: BurlyStoreLocation = .applicationDefault,
        clock: any WallClock = SystemWallClock()
    ) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .phone, at: location, clock: clock)
    }

    /// Watch store: working set only (§1 store shape). See `.phone(at:)`.
    public static func watch(
        at location: BurlyStoreLocation = .applicationDefault,
        clock: any WallClock = SystemWallClock()
    ) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .watch, at: location, clock: clock)
    }

    // MARK: - Exercises

    public func createExercise(_ exercise: ExerciseData) throws {
        guard try model(Exercise.self, id: exercise.id) == nil else {
            throw BurlyStoreError.duplicateID(exercise.id)
        }
        context.insert(
            Exercise(
                id: exercise.id,
                name: exercise.name,
                muscleGroups: exercise.muscleGroups,
                origin: exercise.origin,
                needsNaming: exercise.needsNaming,
                archivedAt: exercise.archivedAt
            )
        )
        try commit()
    }

    public func exercise(id: UUID) throws -> ExerciseData? {
        try model(Exercise.self, id: id)?.snapshot()
    }

    public func exercises(includingArchived: Bool) throws -> [ExerciseData] {
        // Filtering in Swift rather than in the predicate: the catalog is
        // ~100 rows (§9) and `archivedAt == nil` predicates over optional
        // Dates are a well-known SwiftData sharp edge. Revisit if the
        // catalog ever stops being tiny.
        let all = try context.fetch(
            FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.name)])
        )
        return all
            .filter { includingArchived || $0.archivedAt == nil }
            .map { $0.snapshot() }
    }

    public func archiveExercise(id: UUID, at date: Date) throws {
        guard let exercise = try model(Exercise.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        exercise.archivedAt = date
        try commit()
    }

    // MARK: - Routines

    public func createRoutine(_ routine: RoutineData) throws {
        guard try model(Routine.self, id: routine.id) == nil else {
            throw BurlyStoreError.duplicateID(routine.id)
        }

        // Everything that can reject this create runs *before* the first
        // insert (m1-06 review, M1). The old order — insert the parent,
        // then resolve item references one at a time — left the inserted
        // Routine and any already-inserted items pending in a long-lived
        // context after the throw, where the next successful `save()` on
        // any other method would silently commit them. `updateRoutine` was
        // already written this way; now every create is.
        let resolved = try preflightRoutineItems(routine, ownedBy: nil)

        let stored = Routine(
            id: routine.id,
            name: routine.name,
            orderIndex: routine.orderIndex,
            // Store-owned (m1-06 review, m2): a locally-authored routine is
            // dated by the store's clock, not by whatever the DTO carried.
            // The replicated path that must preserve the author's timestamp
            // is `applyRoutineSnapshot`.
            updatedAt: clock.now,
            archivedAt: routine.archivedAt
        )
        context.insert(stored)
        insertRoutineItems(routine.items, resolved: resolved, into: stored)

        try commit()
    }

    public func routine(id: UUID) throws -> RoutineData? {
        try model(Routine.self, id: id)?.snapshot()
    }

    public func routines(includingArchived: Bool) throws -> [RoutineData] {
        let all = try context.fetch(
            FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.orderIndex)])
        )
        // `orderIndex` ties are permitted (see the protocol doc on
        // `updateRoutine`) and `SortDescriptor` alone doesn't promise a
        // stable order across them. Break ties on `id` — compared as a
        // string, since `UUID` isn't `Comparable` — so the fetch order is
        // fully deterministic instead of merely "whatever SwiftData or
        // Swift's sort happened to leave it as."
        return all
            .filter { includingArchived || $0.archivedAt == nil }
            .sorted { lhs, rhs in
                lhs.orderIndex != rhs.orderIndex
                    ? lhs.orderIndex < rhs.orderIndex
                    : lhs.id.uuidString < rhs.id.uuidString
            }
            .map { $0.snapshot() }
    }

    public func archiveRoutine(id: UUID, at date: Date) throws {
        guard let routine = try model(Routine.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        routine.archivedAt = date
        // Store-maintained mutation metadata (m1-04 review): archiving is a
        // mutation of the stored routine, so it bumps `updatedAt` too — the
        // same `date` already given for `archivedAt`, not a second,
        // independently-sourced clock reading for the same event.
        routine.updatedAt = date
        try commit()
    }

    public func deleteRoutine(id: UUID) throws {
        guard let routine = try model(Routine.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        context.delete(routine)
        try commit()
    }

    public func updateRoutine(_ routine: RoutineData) throws {
        guard let stored = try model(Routine.self, id: routine.id) else {
            throw BurlyStoreError.notFound(routine.id)
        }

        // Resolve every item's exercise reference — and prove every item id
        // is this routine's own or unowned — before mutating anything: a
        // rejected update must leave the stored routine untouched, not
        // half-replaced with its old items already deleted.
        let resolved = try preflightRoutineItems(routine, ownedBy: stored)

        stored.name = routine.name
        stored.orderIndex = routine.orderIndex
        // Store-maintained mutation metadata (m1-04 review): `updatedAt` is
        // set from the store's own clock, not copied from `routine.updatedAt`
        // — a caller (or a stale round-tripped DTO) cannot claim an edit
        // happened earlier or later than it actually did. See the protocol
        // doc on `updateRoutine`.
        stored.updatedAt = clock.now
        // `archivedAt` is deliberately not assigned here — see the
        // protocol doc on `updateRoutine`.

        replaceRoutineItems(of: stored, with: routine.items, resolved: resolved)

        try commit()
    }

    public func applyRoutineSnapshot(_ routine: RoutineData) throws {
        let stored = try model(Routine.self, id: routine.id)
        let resolved = try preflightRoutineItems(routine, ownedBy: stored)

        let target: Routine
        if let stored {
            target = stored
        } else {
            let created = Routine(
                id: routine.id,
                name: routine.name,
                orderIndex: routine.orderIndex,
                updatedAt: routine.updatedAt,
                archivedAt: routine.archivedAt
            )
            context.insert(created)
            target = created
        }

        target.name = routine.name
        target.orderIndex = routine.orderIndex
        // The whole point of this path (m1-06 review, m2): the *author's*
        // timestamp and archive state are the payload, so they are copied
        // verbatim. The store's clock is not consulted, and `archivedAt` is
        // assigned here even though `updateRoutine` refuses to — a snapshot
        // replaces the replica wholesale, including whether the author has
        // archived it.
        target.updatedAt = routine.updatedAt
        target.archivedAt = routine.archivedAt

        replaceRoutineItems(of: target, with: routine.items, resolved: resolved)

        try commit()
    }

    // MARK: - Sessions

    public func createSession(_ session: SessionData) throws {
        // In-flight sessions are born through `saveActiveSession` and
        // nowhere else (m1-06 review round D). An `.active` row created
        // here would have no `ActiveSessionJournal` beside it: invisible to
        // Resume, so unfinishable and — since the prune skips `.active`
        // ids — unprunable too. `SessionData.state` defaults to `.active`,
        // so this guard is doing real work, not covering a typo.
        guard session.state != .active else {
            throw BurlyStoreError.activeSessionRequiresSaveActiveSession(sessionID: session.id)
        }
        guard try model(Session.self, id: session.id) == nil else {
            throw BurlyStoreError.duplicateID(session.id)
        }

        // Same rule as `createRoutine` (m1-06 review, M1): every exercise
        // reference resolves and every item/set id is proved unowned before
        // the first insert, so a rejection cannot leave a partial graph
        // pending for someone else's `save()` to commit.
        let resolved = try preflightSessionGraph(session, ownedBy: nil)

        let stored = Session(
            id: session.id,
            routineID: session.routineID,
            routineName: session.routineName,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            state: session.state,
            revision: session.revision,
            healthKitWorkoutID: session.healthKitWorkoutID,
            origin: session.origin,
            notes: session.notes
        )
        context.insert(stored)
        reconcileSessionGraph(stored, to: session, resolved: resolved)

        try commit()
    }

    public func session(id: UUID) throws -> SessionData? {
        try model(Session.self, id: id)?.snapshot()
    }

    public func sessions() throws -> [SessionData] {
        try context.fetch(
            FetchDescriptor<Session>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        )
        .map { try $0.snapshot() }
    }

    public func sessions(state: SessionState) throws -> [SessionData] {
        // Filtering in Swift, not in the predicate: same rationale as
        // `loggedSessionsAwaitingAck` — enum equality in `#Predicate` is a
        // well-known SwiftData sharp edge, and history is small (§ arch).
        try context.fetch(
            FetchDescriptor<Session>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        )
        .filter { $0.state == state }
        .map { try $0.snapshot() }
    }

    @discardableResult
    public func deleteSession(id: UUID) throws -> UUID? {
        guard let session = try model(Session.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        let workoutID = session.healthKitWorkoutID
        if let journal = try journalModel(sessionID: id) {
            // `ActiveSessionJournal` references its session by plain UUID,
            // not by relationship (nothing about a §1 entity may depend on
            // this internal table), so SwiftData's cascade cannot reach it.
            // Deleting it here is what keeps "no journal without a session"
            // true — otherwise a discarded mid-session workout would leave
            // a Resume pointer into nothing.
            context.delete(journal)
        }
        context.delete(session)
        try commit()
        return workoutID
    }

    // MARK: - The in-flight session
    //
    // See the protocol doc for the contract. The implementation note that
    // matters here: every method in this section computes everything that
    // could throw *first*, mutates only after that, and saves exactly once.
    // "One transaction" is not a comment — it is the single `commit()` at
    // the bottom of `saveActiveSession`, with nothing above it that can fail
    // partway, and nothing left staged if the save itself fails (see
    // `commit()`).

    public func saveActiveSession(_ active: ActiveSession) throws {
        let violations = active.invariantViolations()
        guard violations.isEmpty else {
            throw BurlyStoreError.invalidActiveSession(
                sessionID: active.id,
                violations: violations
            )
        }

        let stored = try model(Session.self, id: active.session.id)
        // Finish is one-way (m1-06 review round E). Reaching an existing row
        // through this method is only legitimate while that row is still in
        // flight: writing to a `.logged` one would either resurrect it — the
        // `createSession`-at-revision-42 → flip-to-`.active` sequence — or
        // rewrite finished history without the `revision` bump §5 needs to
        // see an edit. Both are `applyPhoneEdit`'s job or nobody's.
        if let stored, stored.state != .active {
            throw BurlyStoreError.sessionNoLongerInFlight(
                sessionID: stored.id,
                storedState: stored.state
            )
        }
        let resolved = try preflightSessionGraph(active.session, ownedBy: stored)
        if active.session.state == .active {
            try preflightSingleInFlight(incoming: active.id)
        }
        // Encoded before any mutation: a payload that will not encode must
        // not leave a half-applied graph behind.
        let payload = try JSONEncoder().encode(ActiveSessionScaffolding(active))
        let journal = try journalModel(sessionID: active.id)

        let target: Session
        if let stored {
            target = stored
        } else {
            let created = Session(
                id: active.session.id,
                routineID: active.session.routineID,
                routineName: active.session.routineName,
                startedAt: active.session.startedAt,
                endedAt: active.session.endedAt,
                state: active.session.state,
                // The only call that ever writes `revision` on this path —
                // and it writes the §1 constant, not the DTO's value
                // (m1-06 review round D). A watch-authored session starts
                // at 1, full stop; taking `active.session.revision` here
                // let a hand-built or round-tripped DTO claim 42 and
                // outrank every real phone edit under §5's "incoming
                // revision ≤ stored revision → drop" rule. Every later
                // `saveActiveSession` leaves the stored value alone (see
                // `reconcileSessionGraph`). `createSession` is where a
                // replicated session's own revision is preserved.
                revision: 1,
                healthKitWorkoutID: active.session.healthKitWorkoutID,
                origin: active.session.origin,
                notes: active.session.notes
            )
            context.insert(created)
            target = created
        }
        reconcileSessionGraph(target, to: active.session, resolved: resolved)

        if active.session.state == .active {
            if let journal {
                journal.payload = payload
                journal.updatedAt = clock.now
            } else {
                context.insert(
                    ActiveSessionJournal(
                        sessionID: active.id,
                        payload: payload,
                        updatedAt: clock.now
                    )
                )
            }
        } else if let journal {
            // Finish, in the same save as the `.logged`/`endedAt` write:
            // the session stops being in flight and its scaffolding stops
            // existing at the same instant, so a crash can never leave a
            // finished session still advertising itself to Resume.
            context.delete(journal)
        }

        try commit()
    }

    public func activeSession(id: UUID) throws -> ActiveSession? {
        guard
            let journal = try journalModel(sessionID: id),
            let stored = try model(Session.self, id: id),
            // Checked rather than assumed, for the same reason
            // `resumableActiveSession()` walks past a stale row (m1-06
            // review round D): every path out of `.active` retires the
            // journal, so a journal beside a finished session should not
            // exist — and if one does, the honest answer is "nothing in
            // flight under that id", not an `ActiveSession` wrapped around
            // a session that is already history.
            stored.state == .active
        else { return nil }
        return try makeActiveSession(stored, journal: journal)
    }

    public func resumableActiveSession() throws -> ActiveSession? {
        // Still bounded (m1-06 review, M4 slice): the journal table holds a
        // row only while a session is in flight, and `saveActiveSession`'s
        // single-in-flight preflight keeps that at one row, so this fetch
        // is a single-row read even on a decade-deep phone store.
        //
        // But it no longer *assumes* one row, and specifically no longer
        // gives up on the newest one (m1-06 review round D). A single
        // leftover journal — written by an older build, or out-of-band —
        // used to be enough to hide a live workout behind it and answer
        // "nothing to resume". So: newest first, return the first row that
        // names a genuinely `.active` session, and clean up the rows that
        // name a finished or deleted one on the way past. Rows that name
        // *other* live sessions are left strictly alone; this is a read
        // repairing a dangling pointer, not a read deciding which workout
        // the lifter loses.
        let journals = try context.fetch(
            FetchDescriptor<ActiveSessionJournal>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )

        var resumable: (session: Session, journal: ActiveSessionJournal)?
        var stale: [ActiveSessionJournal] = []
        for journal in journals {
            // Predicate + `fetchLimit = 1`, via `model(_:id:)`.
            guard
                let stored = try model(Session.self, id: journal.sessionID),
                stored.state == .active
            else {
                stale.append(journal)
                continue
            }
            if resumable == nil {
                resumable = (stored, journal)
            }
        }

        if stale.isEmpty == false {
            for journal in stale {
                context.delete(journal)
            }
            try commit()
        }

        guard let resumable else { return nil }
        return try makeActiveSession(resumable.session, journal: resumable.journal)
    }

    @discardableResult
    public func applyPhoneEdit(_ session: SessionData) throws -> Int {
        // A §6 edit corrects a session that already happened; it cannot put
        // one back in flight (m1-06 review round D). Only
        // `saveActiveSession` writes an `.active` row, because only it
        // writes the journal that makes the row resumable.
        guard session.state != .active else {
            throw BurlyStoreError.activeSessionRequiresSaveActiveSession(sessionID: session.id)
        }
        guard let stored = try model(Session.self, id: session.id) else {
            throw BurlyStoreError.notFound(session.id)
        }
        let resolved = try preflightSessionGraph(session, ownedBy: stored)
        // Read before the graph is rewritten, so the decision is about the
        // session as it was, not as this edit leaves it.
        let journal = try journalModel(sessionID: session.id)

        reconcileSessionGraph(stored, to: session, resolved: resolved)
        // The one line in this file that moves `revision`. §5's "incoming
        // revision ≤ stored revision → drop silently" rule is only sound
        // while that stays true, so the increment is deliberately not
        // sourced from `session.revision`: a stale DTO cannot roll it back
        // and a forged one cannot jump it forward.
        stored.revision += 1
        if let journal {
            // The guard above proves the session is not `.active` after
            // this edit, so any journal it still carries is now a Resume
            // pointer at a finished session. It goes in the same save as
            // the state change — the rule Finish already followed, applied
            // to the path that used to skip it: a session leaving `.active`
            // retires its journal, whichever method moved it.
            context.delete(journal)
        }

        try commit()
        return stored.revision
    }

    // MARK: - Last-performance digests

    public func lastPerformance(exerciseID: UUID) throws -> ExerciseLastPerformanceData? {
        try lastPerformanceModel(exerciseID: exerciseID)?.snapshot()
    }

    /// **Internal** (m1-06 review round D): one entry, one save, which is
    /// half of a §5 `digest`. Public it was a way to apply the entries
    /// without the prune — or, from the other side, to leave the entries
    /// out of an ack — so the atomicity `applyDigest` provides could be
    /// stepped around by calling something else. The whole-payload method
    /// is the API; this is a convenience the *tests* still want, for
    /// seeding a digest row without asserting anything about the prune.
    func upsertLastPerformance(_ performance: ExerciseLastPerformanceData) throws {
        // §1: the phone derives digests from full history at push time and
        // never stores this entity — only a watch-kind store may write one.
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
        try validateLastPerformance([performance])
        try upsert(performance)
        try commit()
    }

    public func applyDigest(
        lastPerformance: [ExerciseLastPerformanceData],
        ackedSessionIDs: [UUID]
    ) throws {
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
        // Validate the whole payload before touching a row: a digest is one
        // latest-wins fact, so a bad entry rejects the entries *and* the
        // prune (m1-06 review, M2).
        try validateLastPerformance(lastPerformance)
        // Deliberately *not* validated against the sets in the sessions
        // this is about to prune (m1-06 review round F reverting round E) —
        // see `BurlyStore.applyDigest`'s doc. The watch cannot tell "the
        // phone deleted that history" from "the payload is missing
        // entries", and guessing wrong strands the session forever.

        for entry in lastPerformance {
            try upsert(entry)
        }
        try prune(ackedIDs: ackedSessionIDs)

        // The one save. Before this line the process can die at any point
        // and the watch keeps exactly the state the previous digest left;
        // after it, both halves are durable together.
        try commit()
    }

    // MARK: - Watch working set

    public func loggedSessionsAwaitingAck() throws -> [SessionData] {
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
        // Filtering in Swift, not in the predicate: same rationale as
        // `exercises(includingArchived:)` above — the working set is small
        // by construction (that is the whole point of pruning), and enum
        // equality in `#Predicate` is another well-known SwiftData sharp
        // edge alongside optional-Date predicates.
        return try context.fetch(FetchDescriptor<Session>())
            .filter { $0.state == .logged }
            .map { try $0.snapshot() }
    }

    // MARK: - Stats queries (§7; see the protocol doc for why these exist)

    public func loggedSetSlices(
        exerciseID: UUID,
        since: Date?,
        through: Date?
    ) throws -> [SetRecordSlice] {
        try fetchSetSlices(
            predicate: Self.setRecordFilterPredicate(since: since, through: through),
            exerciseID: exerciseID
        )
    }

    public func loggedSetSlices(
        window: TrailingWindow,
        through asOf: Date,
        calendar: Calendar
    ) throws -> [SetRecordSlice] {
        let (since, through) = window.dateRange(asOf: asOf, calendar: calendar)
        return try fetchSetSlices(
            predicate: Self.setRecordFilterPredicate(since: since, through: through),
            exerciseID: nil
        )
    }

    /// Shared fetch/map body for both `loggedSetSlices` overloads above —
    /// they differ only in how the (date-only) predicate and `exerciseID`
    /// are produced. `exerciseID`, when given, is applied entirely below in
    /// Swift, not in `predicate` — see `setRecordFilterPredicate`'s doc for
    /// why relationship traversal was pulled out of the `#Predicate`
    /// entirely (the runner-predicate fix).
    private func fetchSetSlices(
        predicate: Predicate<SetRecord>?,
        exerciseID: UUID?
    ) throws -> [SetRecordSlice] {
        var descriptor = FetchDescriptor<SetRecord>(predicate: predicate)
        // One batched prefetch instead of one fault per row: every slice
        // needs its parent `SessionItem` (for the exercise reference) and
        // that item's `Session` (for `state`/`startedAt`) — the two hops
        // this query exists to avoid amplifying (see the protocol doc).
        descriptor.relationshipKeyPathsForPrefetching = [\.sessionItem, \.sessionItem?.session, \.sessionItem?.exercise]

        // Not a `compactMap`: `SetRecord.snapshot()` throws on a corrupted
        // stored weight (m1-06 review, finding M5), and a stats query
        // should fail the same way every other read of this column does,
        // not silently drop the offending row from a chart.
        var slices: [SetRecordSlice] = []
        for record in try context.fetch(descriptor) {
            guard
                let item = record.sessionItem,
                let session = item.session,
                // Swift-side, not in the predicate: `SessionState` cannot be
                // captured in a `#Predicate` (see the protocol doc). The
                // date bound already applied above is what keeps this from
                // degenerating into a full-history scan for every
                // date-bounded range — the one range that cannot bound
                // itself by date (all-time, one exercise) pays for that
                // with a full fetch; see `setRecordFilterPredicate`'s doc.
                session.state == .logged,
                // The only exercise filter — not a backup for a predicate
                // check, since the predicate no longer touches the
                // relationship at all (the runner-predicate fix). A
                // `sessionItem` or `exercise` link that is nil cannot equal
                // a non-nil `exerciseID`, so it is excluded here exactly as
                // it would have been by either predicate shape that was
                // tried and rejected.
                exerciseID == nil || item.exercise?.id == exerciseID
            else { continue }
            slices.append(
                SetRecordSlice(
                    sessionID: session.id,
                    sessionStartedAt: session.startedAt,
                    exerciseID: item.exercise?.id,
                    set: try record.snapshot()
                )
            )
        }
        return slices
    }

    public func loggedSessionDates(since: Date, through: Date?) throws -> [Date] {
        // No relationship prefetching: this query never touches `.items`,
        // so there is nothing beyond the row itself to fault.
        let descriptor = FetchDescriptor<Session>(
            predicate: Self.sessionDatePredicate(since: since, through: through)
        )
        return try context.fetch(descriptor)
            .filter { $0.state == .logged }
            .map(\.startedAt)
    }

    public func allLoggedSessionDates() throws -> [Date] {
        // No predicate at all: the deliberate, documented exemption — see
        // the protocol doc on this method for why an unbounded fetch is
        // safe here specifically.
        let descriptor = FetchDescriptor<Session>()
        return try context.fetch(descriptor)
            .filter { $0.state == .logged }
            .map(\.startedAt)
    }

    // MARK: - Phone-shell existence/count (m5-01; bounded)
    //
    // m5-01 review round 2, finding 1: round 1 (401646f) shipped both
    // methods fetching the *entire* table into a Swift array and
    // counting/`contains`-ing there — the exact anti-pattern this pair
    // exists to eliminate. Merge note (2026-08-02): relationship
    // optional-chaining in `#Predicate` DID crash the macos-26 CI runner
    // (TERNARY translation, run 30731585827 — see the third-divergence
    // comment at `setRecordFilterPredicate`, which is why that predicate
    // is date-only today). The traps that matter here are: `SessionState`
    // cannot be captured in a `#Predicate` (throws at runtime —
    // `swiftDataCannotPredicateOnSessionState`), relationship chains are
    // runner-fatal, and neither blocks a predicate on a model's own
    // stored, non-relationship column, which is all `hasRoutines()` needs.

    public func hasRoutines() throws -> Bool {
        // A real predicate, pushed to SQL: `archivedAt` is `Routine`'s own
        // stored column (no relationship hop), so this isn't the
        // enum-in-`#Predicate` trap or a relationship-chain concern at all.
        // `fetchLimit = 1` turns "is there one" into a fetch that stops at
        // the first match instead of materializing the whole table into a
        // Swift array first, the way round 1 did.
        var descriptor = FetchDescriptor<Routine>(
            predicate: #Predicate { $0.archivedAt == nil }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty == false
    }

    public func loggedSessionCount() throws -> Int {
        // There genuinely is no SQL-level `state == .logged` to write here
        // — `swiftDataCannotPredicateOnSessionState` pins that `#Predicate`
        // on `SessionState` throws at runtime, not merely that it's
        // stylistically avoided. The honest bounded shape per the review's
        // own suggested fallback: total `Session` count minus the
        // `ActiveSessionJournal` row count, both real `fetchCount`
        // aggregates (SQL `COUNT`, no row materialization) rather than a
        // fetched-then-filtered array.
        //
        // This is exact, not approximate, because of `ActiveSessionJournal`'s
        // own invariant (see that model's doc): a journal row exists *iff*
        // its session is `.active`, and `createSession`/`saveActiveSession`
        // together guarantee an `.active` row can only be born through
        // `saveActiveSession`, which always writes the paired journal row
        // in the same transaction. So `.active` session count ==
        // `ActiveSessionJournal` row count exactly, `SessionState` has only
        // two cases (`.active`, `.logged`), and "total minus active" is
        // ".logged count," full stop — not "logged count, assuming no other
        // states exist."
        let total = try context.fetchCount(FetchDescriptor<Session>())
        let active = try context.fetchCount(FetchDescriptor<ActiveSessionJournal>())
        return total - active
    }

    /// **Internal** (m1-06 review round D), for the mirror-image reason
    /// `upsertLastPerformance` is: the prune on its own, in its own save,
    /// is the half of a §5 `digest` whose isolation the M2 finding was
    /// about. Nothing outside this module should be able to commit an ack
    /// without the entries that arrived with it. Kept because
    /// `applyDigest`'s prune semantics deserve their own unit tests, and
    /// because `applyDigest` is built from the same `prune(ackedIDs:)`.
    func pruneDeliveredSessions(ackedIDs: [UUID]) throws {
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
        try prune(ackedIDs: ackedIDs)
        try commit()
    }

    // MARK: - Catalog seed

    /// One-save, additive seed application. Version metadata and newly
    /// inserted exercises commit atomically in this context.
    ///
    /// Matching is by the permanent seed UUID only. No property of an
    /// existing Exercise is assigned here, so a user's rename, muscle-tag
    /// edit, origin, naming state, and archive timestamp all survive both a
    /// same-version reapply and a later additive seed bump.
    func applyCatalogSeed(_ seed: CatalogSeed) throws -> Int {
        let key = CatalogSeedState.exerciseCatalogKey
        var stateDescriptor = FetchDescriptor<CatalogSeedState>(
            predicate: #Predicate { $0.key == key }
        )
        stateDescriptor.fetchLimit = 1
        let state = try context.fetch(stateDescriptor).first

        guard (state?.version ?? 0) < seed.seedVersion else { return 0 }

        let existingIDs = Set(
            try context.fetch(FetchDescriptor<Exercise>()).map(\.id)
        )
        var insertedCount = 0
        for seeded in seed.exercises where existingIDs.contains(seeded.id) == false {
            context.insert(
                Exercise(
                    id: seeded.id,
                    name: seeded.name,
                    muscleGroups: seeded.muscleGroups,
                    origin: .curated,
                    needsNaming: false,
                    archivedAt: nil
                )
            )
            insertedCount += 1
        }

        if let state {
            state.version = seed.seedVersion
        } else {
            context.insert(CatalogSeedState(version: seed.seedVersion))
        }
        try commit()
        return insertedCount
    }

    // MARK: - Internals

    /// **The only `save()` in this file.** Every mutating method ends here,
    /// and a failed save discards its own pending changes before the error
    /// leaves the store (m1-06 review round E).
    ///
    /// Preflight is what makes a *rejected* call leave nothing behind — it
    /// throws before the first insert. But a save can also fail after the
    /// mutations are staged: the store is full, the file is unwritable, a
    /// SwiftData validation trips. Autosave is off and the `ModelContext`
    /// outlives the call, so without this the staged rows would still be
    /// pending afterwards, and the next successful `save()` — from some
    /// unrelated method minutes later — would commit them. That is the same
    /// class of bug as the create-residue finding (M1), reached through a
    /// failing save instead of a thrown precondition, and it is worse: the
    /// caller has already been told the operation failed.
    ///
    /// `rollback()` returns the context to its last-saved state, so a
    /// failure is a genuine no-op rather than a deferred surprise. The error
    /// is rethrown unchanged — this recovers the context, it does not
    /// swallow anything or retry.
    private func commit() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// One `Predicate<SetRecord>` per presence combination of `since`/
    /// `through` (four, all spelled out), rather than one clever expression
    /// that tries to cover both — same rationale as `sessionDatePredicate`
    /// below: `#Predicate`'s macro needs a literal comparison against a
    /// non-optional bound at each call site.
    ///
    /// This predicate is date-only, deliberately: it never touches
    /// `sessionItem` or `exercise`, only `completedAt`. Exercise scoping
    /// happens in Swift, in `fetchSetSlices`' post-fetch filter
    /// (`exerciseID == nil || item.exercise?.id == exerciseID`) — the third
    /// pinned runner/Darwin-27 divergence in this codebase (see
    /// `ActiveSessionJournal.swift` for the enum-in-predicate one and
    /// `MigrationSpikeTests.swift`/`MigrationSpikeSchemaV2.swift` for the
    /// schema-cache one) forced this predicate out of the relationship
    /// business entirely. Two shapes were tried and both failed, for two
    /// different reasons:
    ///
    /// 1. **Optional chaining** — `$0.sessionItem?.exercise?.id ==
    ///    exerciseID` — is what m6-01 originally shipped, and Darwin 27
    ///    runs it without complaint. But `#Predicate`'s macro expands `?.`
    ///    into a conditional (`PredicateExpressions.flatMap`) node, and
    ///    CoreData's macos-26 SQL translator turns that into `TERNARY
    ///    (sessionItem != nil, sessionItem.exercise, nil).id`, which it then
    ///    refuses to execute: "Unsupported function expression TERNARY(…)",
    ///    crashing package-tests with signal 6 at every one of this
    ///    predicate's four exercise-bound call sites. Nothing about the
    ///    query changed between the two OS builds — only which
    ///    conditional-expression shapes their CoreData SQL layers support,
    ///    same as the enum and schema-cache divergences before it.
    /// 2. **Force-unwrap** — `$0.sessionItem!.exercise!.id == exerciseID` —
    ///    was tried next, on the theory that `!` compiles to a plain
    ///    key-path/SQL-join node with no conditional branch to reject. It
    ///    does not get that far: SwiftData refuses it *locally, on Darwin
    ///    27*, before any CoreData SQL translation happens —
    ///    `SwiftDataError.unsupportedPredicate("The
    ///    'Foundation.PredicateExpressions.ForcedUnwrap' operator is not
    ///    supported")`, thrown by every test that reached this predicate
    ///    (measured; see this task's handoff). So the "force-unwrap avoids
    ///    TERNARY" theory is wrong, not merely unverifiable — `!` inside
    ///    `#Predicate` is unsupported outright, independent of which
    ///    runner's CoreData is on the other end.
    ///
    /// The fix is the two-step fetch the runner hotfix's brief called for
    /// as the fallback: this predicate stays relationship-free (both OS
    /// builds compile plain `Date` comparisons identically — no divergence
    /// possible), and `fetchSetSlices` filters `exerciseID` afterward, in
    /// Swift, over the fetched `SessionItem`/`Exercise` objects it already
    /// prefetches. That filter already existed as a "belt-and-suspenders"
    /// check behind the (now-removed) predicate pushdown; it is now the
    /// only exercise filter, not a backup one.
    ///
    /// **This has a real, measured performance cost**, not a hidden one:
    /// the PR chart's "all-time, one exercise" query — the one range that
    /// cannot bound itself by date — regresses from the exercise-pushed-down
    /// shape's 0.51 s / 40 MB back to a full-history fetch. Re-measured on
    /// `StatsQueryBenchmarkTests`' 50k-row store (50,351 SetRecords, 3,600
    /// sessions) after this fix: **2.41 s, process high-water RSS 187.1 MB**
    /// for the same 4,306-row result (up from 29.5 MB after the preceding
    /// trailing-window query in the same run — see that file's `measure`
    /// doc for why "process high-water," not "this call's own peak," is the
    /// honest framing). This regresses materially past the fix brief's ~1 s
    /// concern threshold, and is reported here loudly rather than hidden:
    /// the two-step fetch is the only predicate shape SwiftData/CoreData
    /// accepts on both the runner and Darwin 27, so restoring the
    /// pushed-down performance means either a different query shape (e.g. a
    /// denormalized `exerciseID` column directly on `SetRecord`, avoiding
    /// the relationship traversal a `#Predicate` entirely) or waiting on a
    /// CoreData/SwiftData fix — both out of scope for this hotfix. Every
    /// date-bounded query (which is every other §7 range) is unaffected,
    /// because dates were never the problem: in the same benchmark run, the
    /// trailing-90-day query across all exercises ran in 0.11 s.
    private static func setRecordFilterPredicate(
        since: Date?,
        through: Date?
    ) -> Predicate<SetRecord>? {
        switch (since, through) {
        case (nil, nil):
            return nil
        case let (since?, nil):
            return #Predicate<SetRecord> { $0.completedAt >= since }
        case let (nil, through?):
            return #Predicate<SetRecord> { $0.completedAt <= through }
        case let (since?, through?):
            return #Predicate<SetRecord> { $0.completedAt >= since && $0.completedAt <= through }
        }
    }

    /// `Session`'s counterpart to `setRecordFilterPredicate(since:through:)`,
    /// bounding `startedAt` instead of `completedAt` (and with no exercise
    /// dimension — `loggedSessionDates` never has one).
    /// `since` is non-optional (m6-01 fix round 2, review item 7:
    /// `loggedSessionDates(since:through:)`'s `since` parameter is now a
    /// plain `Date`, so there is no `nil` case left to switch on here —
    /// the fully-unbounded fetch lives only in `allLoggedSessionDates()`,
    /// which builds its own predicate-less `FetchDescriptor` directly).
    private static func sessionDatePredicate(since: Date, through: Date?) -> Predicate<Session> {
        if let through {
            return #Predicate<Session> { $0.startedAt >= since && $0.startedAt <= through }
        }
        return #Predicate<Session> { $0.startedAt >= since }
    }

    /// Single fetch-by-id helper. `id` is unique on every model, so
    /// `fetchLimit = 1` is exact, not a guess.
    private func model<T: PersistentModel & IdentifiedByUUID>(
        _ type: T.Type,
        id: UUID
    ) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: T.predicate(id: id))
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func lastPerformanceModel(exerciseID: UUID) throws -> ExerciseLastPerformance? {
        var descriptor = FetchDescriptor<ExerciseLastPerformance>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func journalModel(sessionID: UUID) throws -> ActiveSessionJournal? {
        var descriptor = FetchDescriptor<ActiveSessionJournal>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func makeActiveSession(
        _ stored: Session,
        journal: ActiveSessionJournal
    ) throws -> ActiveSession {
        let scaffolding: ActiveSessionScaffolding
        do {
            scaffolding = try JSONDecoder().decode(
                ActiveSessionScaffolding.self,
                from: journal.payload
            )
        } catch {
            throw BurlyStoreError.unreadableActiveSessionJournal(sessionID: stored.id)
        }
        return ActiveSession(
            session: try stored.snapshot(),
            plans: scaffolding.plans,
            restTimer: scaffolding.restTimer
        )
    }

    /// nil means "no exercise attached" (spec allows `exercise: Exercise?`).
    /// A non-nil id that isn't stored is a caller bug, not a nullable field.
    private func resolveExercise(_ id: UUID?) throws -> Exercise? {
        guard let id else { return nil }
        guard let exercise = try model(Exercise.self, id: id) else {
            throw BurlyStoreError.missingExercise(id)
        }
        return exercise
    }

    // MARK: - Preflight
    //
    // Every write path in this file runs its whole rejection surface before
    // it touches a single row (m1-06 review, M1). The context outlives any
    // one call and autosave is off, so a method that inserts first and
    // validates second leaves its rejected rows *pending* — and the next
    // successful `save()`, from an unrelated method, commits them. Preflight
    // is what makes "a rejected call changed nothing" true rather than
    // hopeful.

    /// Resolves every routine item's exercise reference, in item order, and
    /// proves no item id belongs to a routine other than `owner`.
    private func preflightRoutineItems(
        _ routine: RoutineData,
        ownedBy owner: Routine?
    ) throws -> [Exercise?] {
        let owned = Set(owner?.items.map(\.id) ?? [])
        var seen = Set<UUID>()
        for item in routine.items {
            guard seen.insert(item.id).inserted else {
                throw BurlyStoreError.duplicateID(item.id)
            }
            guard owned.contains(item.id) == false else { continue }
            if try model(RoutineItem.self, id: item.id) != nil {
                throw BurlyStoreError.duplicateID(item.id)
            }
        }
        return try routine.items.map { try resolveExercise($0.exerciseID) }
    }

    /// Resolves every session item's exercise reference, in item order, and
    /// proves every item and set id in the payload is either already
    /// `owner`'s or unowned.
    ///
    /// The id checks are not paranoia: `id` is `@Attribute(.unique)` on all
    /// three entities, and SwiftData resolves a duplicate insert by
    /// *merging* rather than failing (see `BurlyStoreError.duplicateID`).
    /// Without this, a payload that reused another session's set id would
    /// silently steal that row.
    private func preflightSessionGraph(
        _ session: SessionData,
        ownedBy owner: Session?
    ) throws -> [Exercise?] {
        let ownedItems = Set(owner?.items.map(\.id) ?? [])
        let ownedSets = Set(owner?.items.flatMap { $0.sets.map(\.id) } ?? [])

        var seenItems = Set<UUID>()
        var seenSets = Set<UUID>()
        for item in session.items {
            guard seenItems.insert(item.id).inserted else {
                throw BurlyStoreError.duplicateID(item.id)
            }
            if ownedItems.contains(item.id) == false,
               try model(SessionItem.self, id: item.id) != nil {
                throw BurlyStoreError.duplicateID(item.id)
            }
            for set in item.sets {
                guard seenSets.insert(set.id).inserted else {
                    throw BurlyStoreError.duplicateID(set.id)
                }
                if ownedSets.contains(set.id) == false,
                   try model(SetRecord.self, id: set.id) != nil {
                    throw BurlyStoreError.duplicateID(set.id)
                }
            }
        }
        return try session.items.map { try resolveExercise($0.exerciseID) }
    }

    /// Proves no session other than `incoming` is currently in flight
    /// (m1-06 review round D).
    ///
    /// §2 performs one workout at a time and `resumableActiveSession()`
    /// promises *the* session to offer, so "which of the two do we resume?"
    /// is a question with no good answer — the store refuses to create it
    /// rather than resolving it by recency and quietly stranding the loser.
    /// Finish or discard the session in flight first.
    ///
    /// The journal table is the index this is asked of, not `Session`: it
    /// holds a row exactly while a session is `.active` (that is now true
    /// by construction — `createSession` refuses `.active`, every path out
    /// of `.active` retires the journal, and this method keeps the table at
    /// one row), so the check costs a bounded fetch instead of a scan of
    /// history. A journal whose session is gone or already finished does
    /// not block anything; `resumableActiveSession()` is what clears it.
    private func preflightSingleInFlight(incoming id: UUID) throws {
        let journals = try context.fetch(FetchDescriptor<ActiveSessionJournal>())
        for journal in journals where journal.sessionID != id {
            guard
                let other = try model(Session.self, id: journal.sessionID),
                other.state == .active
            else { continue }
            throw BurlyStoreError.activeSessionAlreadyInFlight(
                existingID: other.id,
                incomingID: id
            )
        }
    }

    /// No `weightKg` finite/non-negative check here (m1-06 review, fix
    /// round B — reconciling with M2's original weightKg gate, which this
    /// replaces): a `[SetSnapshot]` value cannot carry an invalid
    /// `weightKg` by the time it reaches this function. Both of
    /// `SetSnapshot`'s construction paths are closed at the `Weight`
    /// boundary — `init(weight:reps:isWarmup:)` only accepts an already-
    /// valid `Weight` (its non-throwing initializers trap on a non-finite
    /// or negative value), and `SetSnapshot`'s own custom `Decodable`
    /// throws before producing a value at all. There is no ingress —
    /// programmatic or wire — through which a caller could still hand this
    /// function a `weightKg` this check could catch. A runtime check for an
    /// unreachable condition is not defense in depth, it's dead code that
    /// invites the next reader to assume a threat model that no longer
    /// exists, so it was removed along with `BurlyStoreError
    /// .invalidLastPerformance`. Duplicate-`exerciseID` detection is a
    /// different story — nothing about `Weight` prevents two entries from
    /// naming the same exercise — so that check stays.
    private func validateLastPerformance(
        _ entries: [ExerciseLastPerformanceData]
    ) throws {
        var seen = Set<UUID>()
        for entry in entries {
            guard seen.insert(entry.exerciseID).inserted else {
                // Two entries claiming latest-wins for one exercise: the
                // payload does not say which one wins, so none of it lands.
                throw BurlyStoreError.duplicateID(entry.exerciseID)
            }
        }
    }

    // MARK: - Row mutation (no saves; callers own the transaction)

    private func insertRoutineItems(
        _ items: [RoutineItemData],
        resolved: [Exercise?],
        into routine: Routine
    ) {
        for (item, exercise) in zip(items, resolved) {
            let storedItem = RoutineItem(
                id: item.id,
                exercise: exercise,
                order: item.order,
                defaultSetCount: item.defaultSetCount,
                restOverride: item.restOverride,
                note: item.note
            )
            context.insert(storedItem)
            routine.items.append(storedItem)
        }
    }

    /// Wholesale item replacement — the protocol doc on `updateRoutine`
    /// explains why routines diff by replacement rather than by id.
    private func replaceRoutineItems(
        of routine: Routine,
        with items: [RoutineItemData],
        resolved: [Exercise?]
    ) {
        for item in routine.items {
            context.delete(item)
        }
        routine.items.removeAll()
        insertRoutineItems(items, resolved: resolved, into: routine)
    }

    /// Brings `stored`'s graph to exactly `session`, reusing rows by id.
    ///
    /// Sessions reconcile by id rather than by replacement (the opposite of
    /// routines) because their children *are* referenced across time: a
    /// `SetRecord` written at tap time is history, and deleting and
    /// reinserting it on every mid-session edit would churn rows the §2
    /// crash-recovery story depends on.
    ///
    /// **`revision` is deliberately absent from this method.** Callers that
    /// are allowed to move it do so themselves, in exactly one place each
    /// (`applyPhoneEdit`); callers that are not, cannot.
    private func reconcileSessionGraph(
        _ stored: Session,
        to session: SessionData,
        resolved: [Exercise?]
    ) {
        stored.routineID = session.routineID
        stored.routineName = session.routineName
        stored.startedAt = session.startedAt
        stored.endedAt = session.endedAt
        stored.state = session.state
        stored.healthKitWorkoutID = session.healthKitWorkoutID
        stored.origin = session.origin
        stored.notes = session.notes

        let incomingIDs = Set(session.items.map(\.id))
        var existing: [UUID: SessionItem] = [:]
        var dropped: [SessionItem] = []
        for item in stored.items {
            if incomingIDs.contains(item.id) {
                existing[item.id] = item
            } else {
                dropped.append(item)
            }
        }
        stored.items.removeAll { incomingIDs.contains($0.id) == false }
        for item in dropped {
            context.delete(item)
        }

        for (item, exercise) in zip(session.items, resolved) {
            let target: SessionItem
            if let found = existing[item.id] {
                found.exercise = exercise
                found.order = item.order
                target = found
            } else {
                let inserted = SessionItem(id: item.id, exercise: exercise, order: item.order)
                context.insert(inserted)
                stored.items.append(inserted)
                target = inserted
            }
            reconcileSets(of: target, to: item.sets)
        }
    }

    private func reconcileSets(of item: SessionItem, to sets: [SetRecordData]) {
        let incomingIDs = Set(sets.map(\.id))
        var existing: [UUID: SetRecord] = [:]
        var dropped: [SetRecord] = []
        for set in item.sets {
            if incomingIDs.contains(set.id) {
                existing[set.id] = set
            } else {
                dropped.append(set)
            }
        }
        item.sets.removeAll { incomingIDs.contains($0.id) == false }
        for set in dropped {
            context.delete(set)
        }

        for set in sets {
            if let found = existing[set.id] {
                found.order = set.order
                // Through `Weight`, like `makeSetRecord` — the kg-canonical
                // guarantee (§1 acceptance #4) holds on updates too, not
                // just on inserts.
                found.weightKg = set.weight.kg
                found.reps = set.reps
                found.isWarmup = set.isWarmup
                found.completedAt = set.completedAt
            } else {
                let inserted = makeSetRecord(set)
                context.insert(inserted)
                item.sets.append(inserted)
            }
        }
    }

    private func upsert(_ performance: ExerciseLastPerformanceData) throws {
        if let existing = try lastPerformanceModel(exerciseID: performance.exerciseID) {
            existing.performedAt = performance.performedAt
            existing.sets = performance.sets
            return
        }
        context.insert(
            ExerciseLastPerformance(
                exerciseID: performance.exerciseID,
                performedAt: performance.performedAt,
                sets: performance.sets
            )
        )
    }

    /// The §1 pruning rule, without the save — so `pruneDeliveredSessions`
    /// and `applyDigest` share one definition of "delivered" and the latter
    /// can fold it into a larger transaction.
    private func prune(ackedIDs: [UUID]) throws {
        for id in ackedIDs {
            guard
                let session = try model(Session.self, id: id),
                session.state == .logged
            else {
                // Unknown id, or a still-`.active` session: leave it be.
                // See the protocol doc — this is a timing fact, not an
                // error, and it must not abort acks for the other ids.
                continue
            }
            if let journal = try journalModel(sessionID: id) {
                // Defensive: a `.logged` session should already have had
                // its journal retired by Finish. If one survived, it goes
                // with the session rather than lingering as a Resume
                // pointer into a row that no longer exists.
                context.delete(journal)
            }
            context.delete(session)
        }
    }

    /// The only construction path for a stored set. It takes `Weight`, which
    /// is kg-canonical by construction — there is no overload that accepts a
    /// raw pound value (§1 acceptance #4).
    private func makeSetRecord(_ set: SetRecordData) -> SetRecord {
        SetRecord(
            id: set.id,
            order: set.order,
            weight: set.weight,
            reps: set.reps,
            isWarmup: set.isWarmup,
            completedAt: set.completedAt
        )
    }
}

/// Lets `model(_:id:)` be written once instead of once per entity.
/// `#Predicate` needs a concrete key path, so each model supplies its own.
protocol IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Self>
}

extension Exercise: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Exercise> {
        #Predicate { $0.id == id }
    }
}

extension Routine: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Routine> {
        #Predicate { $0.id == id }
    }
}

extension RoutineItem: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<RoutineItem> {
        #Predicate { $0.id == id }
    }
}

extension Session: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Session> {
        #Predicate { $0.id == id }
    }
}

extension SessionItem: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<SessionItem> {
        #Predicate { $0.id == id }
    }
}

extension SetRecord: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<SetRecord> {
        #Predicate { $0.id == id }
    }
}
