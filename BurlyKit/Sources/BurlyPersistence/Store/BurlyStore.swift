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
// `deleteRoutine` *does* exist: §1 archives routines "once referenced", but
// a Session references its routine only by denormalized `routineID` /
// `routineName`, never by object identity — so deleting a routine cascades
// its RoutineItems and provably leaves Exercises and past Sessions
// untouched (§1 acceptance #2). `archiveRoutine` is the normal path (§9).
//
// ## Threading
//
// Conformers are not `Sendable` and neither is `ModelContext`. Create and
// use a store from one isolation domain (the app's `@MainActor` in practice);
// to hand data across an actor boundary, pass the value types this API
// returns, never the store.

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

    /// Throws `BurlyStoreError.duplicateID` if `routine.id` already exists,
    /// or `.missingExercise` if an item names an exercise that isn't stored.
    func createRoutine(_ routine: RoutineData) throws
    func routine(id: UUID) throws -> RoutineData?
    /// Sorted by `orderIndex` (the user's manual order, §9).
    func routines(includingArchived: Bool) throws -> [RoutineData]
    func archiveRoutine(id: UUID, at date: Date) throws
    /// Cascades to RoutineItems only. Exercises and past Sessions survive.
    func deleteRoutine(id: UUID) throws
    /// Overwrites `name`, `orderIndex`, `items`, and `updatedAt` — the
    /// §6/§9 edit path (rename, drag-reorder the routine list via
    /// `orderIndex`, add/remove/reorder `RoutineItem`s). Items are replaced
    /// wholesale rather than merged by id: they carry no identity anything
    /// else references (§1: only `Exercise` is referenced across time), so
    /// a full replace is simpler and no less correct than a diff.
    ///
    /// Deliberately does not touch `archivedAt` — archive state is
    /// `archiveRoutine`'s alone, so an edit can never accidentally
    /// un-archive (or archive) a routine as a side effect. Throws
    /// `.notFound` if `routine.id` isn't stored, or `.missingExercise` if
    /// an item names an exercise that isn't stored — validated before any
    /// row is touched, so a rejected update leaves the stored routine
    /// exactly as it was.
    func updateRoutine(_ routine: RoutineData) throws

    // MARK: - Sessions

    /// Throws `BurlyStoreError.duplicateID` if `session.id` already exists,
    /// or `.missingExercise` if an item names an exercise that isn't stored.
    func createSession(_ session: SessionData) throws
    func session(id: UUID) throws -> SessionData?
    /// Reverse-chronological by `startedAt` (§6 history surface).
    func sessions() throws -> [SessionData]
    /// Sessions in `state`, reverse-chronological like `sessions()`. A
    /// plain read available on either store kind — unlike
    /// `loggedSessionsAwaitingAck` below, this carries no watch-only ack
    /// framing. §2's relaunch-into-Resume path (find the `.active`
    /// session) and §7's stats (all `.logged` sessions) both want a bare
    /// state filter.
    func sessions(state: SessionState) throws -> [SessionData]
    /// The §2 hot path: one set, written and saved immediately at tap time
    /// (architecture doc's crash-recovery layer 1).
    func logSet(_ set: SetRecordData, toSessionItem sessionItemID: UUID) throws
    /// Cascades to items and sets. Returns the linked `healthKitWorkoutID`
    /// if there was one, so the caller can delete the HKWorkout too (§1
    /// deletion rule) — BurlyPersistence does not import HealthKit.
    @discardableResult
    func deleteSession(id: UUID) throws -> UUID?

    // MARK: - Last-performance digests (watch store; §1, §5 `digest`)

    func lastPerformance(exerciseID: UUID) throws -> ExerciseLastPerformanceData?
    /// Latest-wins upsert keyed on `exerciseID` (§5 digest rule).
    func upsertLastPerformance(_ performance: ExerciseLastPerformanceData) throws

    // MARK: - Watch working set (§1 store shape; watch-only)
    //
    // "the watch never accumulates full history — after ack, delivered
    // sessions are pruned from the watch store." These two members are the
    // whole of that rule the store itself can enforce today: what's still
    // waiting, and the prune. The queued courier, ack bookkeeping, and
    // retry policy are BurlySync's M4 job — see `SessionAckApplying`.

    /// Sessions in `.logged` state that have not yet been pruned — the
    /// sync layer's view of the queue. Throws `.operationRequiresWatchStore`
    /// on a phone-kind store: full history makes "awaiting ack" meaningless
    /// there. `.count` on the result is the test-visible working-set size.
    func loggedSessionsAwaitingAck() throws -> [SessionData]

    /// Prunes `.logged` sessions named in `ackedIDs`, cascading their items
    /// and sets — the mechanism that keeps the watch from accumulating full
    /// history. An id naming an `.active` session, or no session at all, is
    /// left untouched rather than throwing: an ack racing a session that
    /// hasn't finished yet, or a duplicate/late ack, is a timing fact, not
    /// an error. Throws `.operationRequiresWatchStore` on a phone-kind
    /// store, before touching anything.
    func pruneDeliveredSessions(ackedIDs: [UUID]) throws
}
