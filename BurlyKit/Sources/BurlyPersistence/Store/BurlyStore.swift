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

    // MARK: - Sessions

    /// Throws `BurlyStoreError.duplicateID` if `session.id` already exists,
    /// or `.missingExercise` if an item names an exercise that isn't stored.
    func createSession(_ session: SessionData) throws
    func session(id: UUID) throws -> SessionData?
    /// Reverse-chronological by `startedAt` (§6 history surface).
    func sessions() throws -> [SessionData]
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
}
