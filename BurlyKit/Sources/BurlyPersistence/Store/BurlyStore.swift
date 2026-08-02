// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyStore — the small protocol the architecture doc puts in front of the
// persistence fork ("BurlyPersistence: the store … domain↔storage mapping
// behind a small protocol"). Everything it speaks is a BurlyCore value type;
// no `@Model` class appears in any signature, so the SwiftData choice stays
// swappable and nothing non-Sendable escapes the module.
//
// ## The shape of this API is a spec constraint, not a style choice
//
// **There is no `deleteExercise`.** Spec §1: exercises are archived, never
// deleted, once any SetRecord references them; §1 acceptance #3 requires
// that a hard delete of a referenced Exercise be *impossible via the store
// API surface*. The method simply does not exist, so no caller — including
// a future one written by someone who never read §1 — can lose history.
// This absence is load-bearing: SwiftData does not enforce the `.deny`
// delete rule Exercise declares (measured; see Models/Exercise.swift), so
// there is no engine-level backstop. Adding the method would silently make
// history destructible. Use `archiveExercise`.
//
// **There is no `logSet`.** Same kind of guarantee, for §2 rather than §1
// (m1-06 review round D). An in-flight session is a session graph *and* an
// `ActiveSessionJournal` describing the plan/timer scaffolding beside it;
// `saveActiveSession(_:)` writes both in one save, and its preflight
// refuses a graph the §2 engine would not recognise. A second method that
// could append one set on its own would necessarily write half of that —
// the set commits, the journal still describes the session as it was, and
// a crash before the next `saveActiveSession` leaves a resumable session
// whose plan claims fewer sets than were logged (invariant I4). Deleting
// the method is what makes "`saveActiveSession` is the only write path for
// an active session" a fact about the API rather than a convention. A
// session that arrives whole and finished still goes through
// `createSession`; a set added to stored history afterwards is a §6 edit,
// which is `applyPhoneEdit` and bumps `revision` as §5 requires.
//
// **There is no `upsertLastPerformance` or `pruneDeliveredSessions`.** Both
// were public once and both are half of a §5 `digest` (m1-06 review round
// D). A digest is one latest-wins payload — new per-exercise entries *and*
// the sessions the phone has received — so a public method that applies
// one half in its own save is a crash window with an API in front of it.
// `applyDigest(lastPerformance:ackedSessionIDs:)` is the whole payload, in
// one transaction; the halves survive as module-internal helpers it is
// built from.
//
// `deleteRoutine` *does* exist: §1 archives routines "once referenced", but
// a Session references its routine only by denormalized `routineID` /
// `routineName`, never by object identity — so deleting a routine cascades
// its RoutineItems and provably leaves Exercises and past Sessions
// untouched (§1 acceptance #2). `archiveRoutine` is the normal path (§9).
//
// ## Threading
//
// `SwiftDataStore` does not declare `Sendable`, but that is not the backstop
// it might look like (m1-06 review, finding m3): the current SDK's
// `ModelContext` is itself `@unchecked Sendable`, and `@Model` classes now
// pick up `Sendable` from the macro, so the type system does not actually
// stop a store — or a model object read from one — from being handed
// across an actor boundary. What contains this is caller-owned discipline
// plus the sealed API surface above (no `@Model` type ever appears in a
// `BurlyStore` signature), not a compiler-enforced guarantee. Create and
// use a store from one isolation domain (the app's `@MainActor` in
// practice); to hand data across an actor boundary, pass the value types
// this API returns, never the store. A dedicated confinement mechanism
// (`@MainActor` or a `ModelActor`) is a later-milestone decision, not made
// here.

import Foundation
import BurlyCore

public protocol BurlyStore: AnyObject {

    // MARK: - Exercises (archive-only; see the note above)

    /// Throws `BurlyStoreError.duplicateID` if `exercise.id` already exists.
    func createExercise(_ exercise: ExerciseData) throws
    func exercise(id: UUID) throws -> ExerciseData?
    /// Sorted by name. `includingArchived: false` hides archived exercises
    /// from pickers while keeping them alive for history (§1).
    func exercises(includingArchived: Bool) throws -> [ExerciseData]
    func archiveExercise(id: UUID, at date: Date) throws

    // MARK: - Routines

    /// **Local authoring.** Creates a routine the user just made on *this*
    /// device, stamping `updatedAt` from the store's own clock — the
    /// caller's `routine.updatedAt` is ignored, exactly as `updateRoutine`
    /// ignores it. A locally-authored routine cannot be born backdated or
    /// postdated (m1-06 review, m2).
    ///
    /// This is not the path for a routine that was authored elsewhere. A
    /// phone-pushed §5 snapshot must land on the watch carrying the
    /// *phone's* timestamp, or the two devices disagree about when the
    /// routine last changed; that is `applyRoutineSnapshot(_:)`.
    ///
    /// Throws `BurlyStoreError.duplicateID` if `routine.id` — or any
    /// item id — already exists, or `.missingExercise` if an item names an
    /// exercise that isn't stored. Every one of those checks runs before
    /// the first insert, so a rejected create leaves nothing pending for a
    /// later save to commit (m1-06 review, M1).
    func createRoutine(_ routine: RoutineData) throws
    func routine(id: UUID) throws -> RoutineData?
    /// Sorted by `orderIndex` (the user's manual order, §9), then by `id`
    /// to make the order deterministic when two routines tie on
    /// `orderIndex`. Ties are permitted: the store does not enforce
    /// uniqueness on `orderIndex`, and reindexing peers when one routine's
    /// index changes — closing gaps, making room for an insert — is caller
    /// policy (see `updateRoutine`), not something this method or
    /// `updateRoutine` does on the store's own initiative.
    func routines(includingArchived: Bool) throws -> [RoutineData]
    /// Also bumps `updatedAt` to `date` — archiving is a mutation of the
    /// stored routine like any other, so it takes the same store-maintained-
    /// metadata treatment `updateRoutine` does (m1-04 review).
    func archiveRoutine(id: UUID, at date: Date) throws
    /// Cascades to RoutineItems only. Exercises and past Sessions survive.
    func deleteRoutine(id: UUID) throws
    /// Overwrites `name`, `orderIndex`, and `items` — the §6/§9 edit path
    /// (rename, drag-reorder the routine list via `orderIndex`,
    /// add/remove/reorder `RoutineItem`s). Items are replaced wholesale
    /// rather than merged by id: they carry no identity anything else
    /// references (§1: only `Exercise` is referenced across time), so a
    /// full replace is simpler and no less correct than a diff.
    ///
    /// `orderIndex` may collide with another stored routine's — that's
    /// permitted (see `routines(includingArchived:)`). This method reindexes
    /// nothing beyond the one routine named: if a caller means "insert at
    /// position 2, shift everything after it," walking and rewriting the
    /// peers' `orderIndex` values is the caller's job, one `updateRoutine`
    /// call per routine touched. The store has no concept of "the whole
    /// list's order" to rebalance on its own.
    ///
    /// `updatedAt` is store-maintained (m1-04 review): the stored value is
    /// set from the store's own clock at the moment of the call, never
    /// copied from `routine.updatedAt` — a caller cannot backdate or
    /// postdate an edit by handing the store a DTO with a stale or
    /// forged timestamp.
    ///
    /// Deliberately does not touch `archivedAt` — archive state is
    /// `archiveRoutine`'s alone, so an edit can never accidentally
    /// un-archive (or archive) a routine as a side effect. Throws
    /// `.notFound` if `routine.id` isn't stored, or `.missingExercise` if
    /// an item names an exercise that isn't stored — validated before any
    /// row is touched, so a rejected update leaves the stored routine
    /// exactly as it was.
    func updateRoutine(_ routine: RoutineData) throws

    /// **Replicated apply**, the counterpart to `createRoutine` /
    /// `updateRoutine` (m1-06 review, m2). This is how a routine that was
    /// authored on the *other* device lands here: §5's `snapshot` payload
    /// is a whole-working-set replace, and the receiving store's job is to
    /// mirror it, not to re-date it.
    ///
    /// So this is the one routine path that **preserves the incoming
    /// `updatedAt` and `archivedAt` verbatim**. The store's clock is not
    /// consulted. Upserts by id: creates the routine when it isn't stored,
    /// replaces name/orderIndex/items/updatedAt/archivedAt wholesale when
    /// it is.
    ///
    /// Available on either store kind — the snapshot direction is a §5
    /// policy question owned by BurlySync, not something the store can or
    /// should second-guess.
    ///
    /// Throws `.missingExercise` for a dangling item reference, or
    /// `.duplicateID` if an item id is already owned by a *different*
    /// routine — both before any row is touched.
    func applyRoutineSnapshot(_ routine: RoutineData) throws

    // MARK: - Sessions

    /// Throws `BurlyStoreError.duplicateID` if `session.id` — or any item
    /// or set id inside it — already exists, or `.missingExercise` if an
    /// item names an exercise that isn't stored. All of it is checked
    /// before the first insert (m1-06 review, M1).
    ///
    /// This is the strict *create*, for a session that arrives whole and
    /// finished: a Hevy import (§8), a §5 `session` payload landing on the
    /// phone. Unlike every other path, it takes `session.revision` at face
    /// value — a replicated session's revision is the author's, and §5's
    /// upsert rule depends on it surviving the trip.
    ///
    /// **Refuses `state == .active`** with
    /// `.activeSessionRequiresSaveActiveSession` (m1-06 review round D).
    /// `SessionData.state` defaults to `.active`, so this is easy to reach
    /// by accident, and the row it used to produce was an in-flight session
    /// with no journal beside it: invisible to Resume, unfinishable,
    /// unprunable. In-flight sessions are born through
    /// `saveActiveSession(_:)` and nowhere else.
    func createSession(_ session: SessionData) throws
    func session(id: UUID) throws -> SessionData?
    /// Reverse-chronological by `startedAt` (§6 history surface).
    func sessions() throws -> [SessionData]
    /// Sessions in `state`, reverse-chronological like `sessions()`. A
    /// plain read available on either store kind — unlike
    /// `loggedSessionsAwaitingAck` below, this carries no watch-only ack
    /// framing. §7's stats (all `.logged` sessions) want a bare state
    /// filter; §2's relaunch-into-Resume path wants
    /// `resumableActiveSession()`, which is bounded and returns the
    /// scaffolding too.
    func sessions(state: SessionState) throws -> [SessionData]
    /// Cascades to items and sets. Returns the linked `healthKitWorkoutID`
    /// if there was one, so the caller can delete the HKWorkout too (§1
    /// deletion rule) — BurlyPersistence does not import HealthKit.
    @discardableResult
    func deleteSession(id: UUID) throws -> UUID?

    // MARK: - The in-flight session (§2/§3; watch-authored)
    //
    // ## One unit of work, and the revision line
    //
    // A workout is not a create followed by a stream of appends. Between
    // Start and Finish the §2 engine changes *persisted* facts: a swap
    // rewrites an item's `exerciseID` or splits the item in two, add /
    // reorder rewrites the item graph, Finish rewrites `state` and
    // `endedAt` — and all of that happens alongside the plan/rest-timer
    // scaffolding §1 has no entity for. Persisting those through separate
    // calls means separate saves, and separate saves mean a crash window in
    // which the stored graph, the newly logged set, and the journal
    // disagree. `saveActiveSession(_:)` is the single transaction that
    // closes that window (m1-06 review, B1).
    //
    // It is also the *only* write path into `.active`, which is what makes
    // the closure real rather than advisory (m1-06 review round D). Three
    // rules together, each enforced by a method in this section:
    //
    // 1. An `.active` row is created only here. `createSession` refuses
    //    `.active`, so no row can exist in flight without the journal that
    //    makes it resumable.
    // 2. A session leaving `.active` retires its journal in the same save,
    //    through *whichever* path moved it — Finish here, a §6 edit through
    //    `applyPhoneEdit`, a discard through `deleteSession`, an ack
    //    through `applyDigest`. No path leaves the pointer behind.
    // 3. At most one session is in flight at a time. §2 performs one
    //    workout, and Resume promises *the* session to offer; a second
    //    `.active` session is refused rather than silently resolved by
    //    recency. See `saveActiveSession(_:)`.
    //
    // The revision line runs straight through this section, so it is worth
    // stating once: **`saveActiveSession` never increments `revision`.**
    // Everything the watch does to a live session — every mutation, and
    // Finish — leaves it at the value the session was created with (§1: 1).
    // `revision` exists for §5's idempotent upsert rule, and exactly one
    // method in this protocol moves it: `applyPhoneEdit(_:)`.

    /// Durably applies one in-flight session, whole, in **one** save.
    ///
    /// M2 calls this after each `SessionMutator` / `SessionEngine`
    /// mutation and once more after Finish. Each call reconciles, together:
    ///
    /// - the `SessionData` graph as the engine now holds it — swapped
    ///   `exerciseID`s, inserted, removed, reordered and renumbered items,
    ///   and every `SetRecordData` logged so far, including the one that
    ///   was just logged;
    /// - the §2/§3 scaffolding (`plans`, `restTimer`) journaled next to
    ///   that graph rather than in a second write a crash could tear away
    ///   from it (§3: "timer state is part of the active session record");
    /// - the Finish transition, which writes `state`/`endedAt` and retires
    ///   the journal — a `.logged` session is no longer in flight.
    ///
    /// Creates the session if it isn't stored yet, so §2 Start is the same
    /// one call as every mutation after it. It is also the only way to
    /// create one: `createSession` refuses `.active`.
    ///
    /// **Revision:** never incremented, and never taken from the DTO —
    /// not on an already-stored session (the stored value survives
    /// untouched however `active.session.revision` reads) and not on the
    /// creating call either, which writes 1 regardless (m1-06 review round
    /// D). §1 says a session starts at 1 and §5 reads a higher revision as
    /// "a human edited this on the phone"; a watch-authored session born at
    /// 42 because a DTO said so would outrank real phone edits forever.
    /// Watch activity has no way to move the number. See
    /// `applyPhoneEdit(_:)`.
    ///
    /// That makes the rule **transitive**, not merely local (m1-06 review
    /// round E). `createSession` refuses `.active`, and this method refuses
    /// an existing row that is not already `.active`, so the only way a row
    /// can be `.active` at all is to have come through the create branch
    /// below — at revision 1. No `.active` session in the store can hold
    /// any other revision, whatever a DTO claims and however many times it
    /// is re-saved. A replicated session's own revision, preserved by
    /// `createSession`, cannot be borrowed by flipping it back into flight.
    ///
    /// **Finish is one-way.** Throws `.sessionNoLongerInFlight` when the
    /// stored session is not `.active` — §4's recovery is finish-or-discard,
    /// never un-finish, so no watch flow writes to a session after it
    /// leaves flight. This also refuses a *second* Finish of the same
    /// session (the first already retired the journal, so nothing
    /// legitimate holds an `ActiveSession` for it); correcting a finished
    /// session is `applyPhoneEdit`, which bumps `revision` as §5 requires.
    ///
    /// **One at a time.** Throws `.activeSessionAlreadyInFlight` if a
    /// *different* session is already `.active`. §2 performs one workout,
    /// and `resumableActiveSession()` promises the session to offer rather
    /// than a choice between two; the store refuses the second start
    /// instead of quietly deciding which one Resume forgets about. Finish
    /// or discard the session in flight first. (Saving the *same* session
    /// again is the normal mutation path and is not affected.)
    ///
    /// Nothing is written until `active.invariantViolations()` is empty,
    /// the stored session (if any) is still in flight, every exercise
    /// reference resolves, every item and set id is either already this
    /// session's or unowned, and no other session is in flight. Throws
    /// `.invalidActiveSession`, `.sessionNoLongerInFlight`,
    /// `.missingExercise`, `.duplicateID`, or
    /// `.activeSessionAlreadyInFlight` respectively, before touching a row.
    func saveActiveSession(_ active: ActiveSession) throws

    /// The in-flight session named by `id`, graph plus journaled
    /// scaffolding, or `nil` when nothing is in flight under that id —
    /// never written by `saveActiveSession`, already finished, or (only
    /// reachable out-of-band) a journal left beside a session that is no
    /// longer `.active`. Throws `.unreadableActiveSessionJournal` if the
    /// journal is present but corrupt.
    func activeSession(id: UUID) throws -> ActiveSession?

    /// §2 Resume: the one session to offer on relaunch, or `nil`.
    ///
    /// **Bounded by construction** (m1-06 review, M4 slice): it reads the
    /// journal index — a table that holds a row only while a session is in
    /// flight, and at most one row at a time given the single-in-flight
    /// rule above — and then fetches the named session by id. Resume costs
    /// a couple of single-row fetches; `sessions(state:)` would materialise
    /// and snapshot the entire stored history to answer the same question.
    /// The rest of the bounded query surface (date ranges, per-exercise
    /// slices, flat set projections) is M6's, not this method's.
    ///
    /// **Robust to an index it did not write** (m1-06 review round D). The
    /// earlier version read exactly the newest journal row and gave up if
    /// that one turned out to be stale — which let a single leftover row
    /// hide a perfectly good session behind it and report "nothing to
    /// resume" over a workout in progress. The rules above mean the store's
    /// own API can no longer produce that state, but a row written by an
    /// older build or out-of-band can, and losing a live workout is not an
    /// acceptable way to find out. So this walks the (few) journal rows
    /// newest-first, returns the first that names a genuinely `.active`
    /// session, and deletes the ones that name a finished or absent
    /// session on the way past — the one read in this protocol that
    /// repairs what it finds, because leaving a Resume pointer into nothing
    /// costs more than the write.
    ///
    /// Throws `.unreadableActiveSessionJournal` if the journal it settles
    /// on is present but corrupt.
    func resumableActiveSession() throws -> ActiveSession?

    /// §6 phone-side edit of a stored session — **the only method in this
    /// protocol that increments `revision`**, and the only place it should
    /// ever be incremented.
    ///
    /// §5's apply rule is "incoming revision ≤ stored revision → drop
    /// silently", which only works if a bump means "a human edited this
    /// after the fact." Watch-authored activity must therefore never bump:
    /// see `saveActiveSession(_:)`, which is that path and does not.
    ///
    /// Replaces the stored graph with `session` — items, sets, notes, HK
    /// link, state, timestamps — then increments the stored revision by
    /// exactly one and returns it. As everywhere else, references and ids
    /// are validated before any row is touched.
    ///
    /// **Refuses `state == .active`** with
    /// `.activeSessionRequiresSaveActiveSession`: a §6 edit is a correction
    /// to a session that already happened, and an edit that put a row back
    /// in flight would produce one with no journal beside it. Editing a
    /// session *out* of `.active` is fine and is the interesting case — it
    /// retires the journal in the same save, so a session the phone
    /// finished on the watch's behalf stops advertising itself to Resume at
    /// the instant it stops being active (m1-06 review round D).
    ///
    /// M1 scope: the transaction and the revision rule. The §6 editor's
    /// own semantics (what the phone is allowed to edit, how a conflicting
    /// concurrent watch session is resolved) are M4's.
    ///
    /// Throws `.notFound` if `session.id` isn't stored.
    @discardableResult
    func applyPhoneEdit(_ session: SessionData) throws -> Int

    // MARK: - Last-performance digests (watch store; §1, §5 `digest`)

    func lastPerformance(exerciseID: UUID) throws -> ExerciseLastPerformanceData?

    /// §5 `digest` apply, as **one transaction** (m1-06 review, M2).
    ///
    /// A digest is a single latest-wins payload carrying both halves of
    /// one fact: here are the new per-exercise last-performance entries,
    /// *and* here are the sessions the phone has durably received. Applying
    /// those halves through separate saves opens a crash window in which
    /// the acked session is already pruned from the watch while its
    /// replacement ghost row is stale or absent — history the watch no
    /// longer holds, described by numbers that never arrived. So: every
    /// entry upserts and every eligible acked session is pruned in the
    /// same context save, or nothing happens at all.
    ///
    /// Validation runs over the whole payload first. A duplicate
    /// `exerciseID` (`.duplicateID`) — two entries claiming latest-wins for
    /// the same exercise, which the payload cannot resolve on its own —
    /// rejects the entire digest, entries and prune alike: a half-applied
    /// latest-wins payload is not a state the phone ever described.
    /// `weightKg` is not a separate validation concern here; it cannot be
    /// invalid on arrival (m1-06 review, fix round B): a `[SetSnapshot]`
    /// cannot carry a negative, NaN, or infinite `weightKg` by the time it
    /// reaches the store — see `Weight`'s doc for why every construction
    /// path is already closed at that boundary.
    ///
    /// **This is the whole payload, and the only public way to apply any of
    /// it** (m1-06 review round D). The single-entry upsert and the bare
    /// prune are module-internal helpers now: a transport that could reach
    /// either one on its own could commit the ack without the entries it
    /// arrived with, which is the crash window this method exists to close.
    /// The transport-facing shape is BurlySync's `SessionDigestReceipt`,
    /// which cannot be constructed with only one half.
    ///
    /// **The entries are trusted, not checked against the prune** (m1-06
    /// review round F, reverting round E). It is tempting to validate them:
    /// an empty `lastPerformance` is a legal digest, so
    /// `applyDigest(lastPerformance: [], ackedSessionIDs: [s])` is
    /// expressible even when `s` is full of sets, and applying it deletes
    /// the watch's last knowledge of those exercises. The store holds the
    /// graph it is about to delete, so it *can* notice. Round E made it
    /// throw. That was wrong, and the reason is worth keeping written down.
    ///
    /// The shape is not evidence of a bug, because the phone is allowed to
    /// forget: §1 gives it `deleteSession`, and §5 has it retain acked ids
    /// for ~30 days. So — watch finishes the only bench session ever; phone
    /// receives and acks it; the user deletes it on the phone; the phone's
    /// next digest is derived from a full history that now genuinely
    /// contains no bench, and it still carries the ack. Honest payload,
    /// exactly the refused shape. Round E threw on it every time, so the
    /// session was never pruned; after 30 days the ack aged out, no later
    /// digest named the session, and it was stranded on the watch forever —
    /// violating §5's "zero delivered-and-acked sessions remain" and
    /// leaving it to be re-delivered as a ghost. A phone edit removing a
    /// session's last sets strands it identically.
    ///
    /// The watch cannot tell the two cases apart; the evidence lives on the
    /// phone. So this is a **trust boundary, enforced upstream**: absence of
    /// an entry asserts "the phone's history holds nothing for this
    /// exercise," and the watch believes it. The obligation to make that
    /// true belongs to the digest generator — see `SessionDigestReceipt`,
    /// which states the contract, and M4, which owns and property-tests it.
    ///
    /// Pruning tolerates what a real transport produces: an id naming an
    /// `.active` session, or no session at all, is skipped rather than
    /// treated as an error, so replaying a digest converges. An acked
    /// session that somehow still carries a journal takes it along.
    /// Watch-only; throws `.operationRequiresWatchStore` on a phone-kind
    /// store before touching anything.
    func applyDigest(
        lastPerformance: [ExerciseLastPerformanceData],
        ackedSessionIDs: [UUID]
    ) throws

    // MARK: - Watch working set (§1 store shape; watch-only)
    //
    // "the watch never accumulates full history — after ack, delivered
    // sessions are pruned from the watch store." The prune itself is
    // `applyDigest`'s second half, because that is how §5 delivers it; what
    // remains here is the read that says what is still waiting. The queued
    // courier, ack bookkeeping, and retry policy are BurlySync's M4 job —
    // see `SessionDigestApplying`.

    /// Sessions in `.logged` state that have not yet been pruned — the
    /// sync layer's view of the queue. Throws `.operationRequiresWatchStore`
    /// on a phone-kind store: full history makes "awaiting ack" meaningless
    /// there. `.count` on the result is the test-visible working-set size.
    func loggedSessionsAwaitingAck() throws -> [SessionData]

    // MARK: - Stats queries (§7; bounded, no full-history graph — m6-01)
    //
    // `sessions()` / `sessions(state:)` return the whole Session →
    // SessionItem → SetRecord graph, unbounded by date — the right shape
    // for "the history screen", wrong for a chart that only ever wants a
    // trailing window (§7: 3 m/6 m/1 y/all, 8/26/52 weeks, a 4-week
    // default). Building §7's stats on either would hydrate and fault the
    // *entire* stored history on every chart render, once per relationship
    // hop, however narrow the requested window actually is — the m1-06
    // adversarial review flagged exactly this session→items→sets
    // amplification and carried the fix into this task's brief.
    //
    // These two queries exist instead: bounded by a `Date` predicate (safe
    // to filter at the SwiftData layer, unlike `SessionState` — see
    // `ActiveSessionJournal.swift`'s pinned finding and
    // `swiftDataCannotPredicateOnSessionState`), and shaped flat —
    // `SetRecordSlice`, or a bare `[Date]` — rather than as the nested
    // domain graph, so a chart's data flows through exactly the fields it
    // needs and nothing shaped like a lazy relationship escapes the store.
    // Both restrict to `.logged` sessions: an `.active` workout is not
    // history yet.

    /// Flat set-level projections for §7's PR, volume, and muscle-split
    /// charts — never the full session graph.
    ///
    /// - Parameters:
    ///   - exerciseID: scopes to one exercise's sets (the PR chart's
    ///     shape); `nil` returns every exercise's (volume and
    ///     muscle-split's shape).
    ///   - since: lower bound on the set's `completedAt`, inclusive; `nil`
    ///     is unbounded below — the PR chart's "all" range is the only §7
    ///     range that ever passes this, since every other range names a
    ///     trailing window.
    ///   - through: upper bound, inclusive; `nil` is unbounded above — the
    ///     common case, since every §7 range reads "since X, through now"
    ///     and callers do not have to compute "now" just to bound it.
    ///
    /// No ordering is promised; every current caller sorts what it gets
    /// back (see `ExerciseProgressionStats.sessionPoints`).
    func loggedSetSlices(exerciseID: UUID?, since: Date?, through: Date?) throws -> [SetRecordSlice]

    /// `startedAt` for every `.logged` session in the window — no item or
    /// set graph — for §7's consistency chart (sessions/week, calendar
    /// dots), which never looks inside a session. Bounded the same way as
    /// `loggedSetSlices`; no ordering promised.
    func loggedSessionDates(since: Date?, through: Date?) throws -> [Date]
}
