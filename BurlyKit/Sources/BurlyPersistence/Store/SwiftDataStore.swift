// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore — the SwiftData implementation of `BurlyStore`
// (architecture doc option A, Dan's pick 2026-07-31).
//
// Autosave is off and every mutating method saves before returning. The
// data is tiny (§ architecture: ~40–50k rows for a decade of lifting) and
// §2 requires a logged set to be durable at tap time; predictable saves are
// worth more here than batching.

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

    /// Internal — see BurlyContainer.swift's boundary doc: `ModelContainer`
    /// must never appear in a public signature of this module. Construct a
    /// store publicly through `.phone(at:)` / `.watch(at:)` /
    /// `init(kind:at:)` instead.
    init(container: ModelContainer) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        let configuredName = container.configurations.first?.name
        self.kind = BurlyStoreKind.allCases.first { $0.storeName == configuredName }
    }

    public convenience init(
        kind: BurlyStoreKind,
        at location: BurlyStoreLocation = .applicationDefault
    ) throws {
        self.init(container: try BurlyContainer.make(kind, at: location))
    }

    /// Phone store: full history (§1 store shape). The public counterpart
    /// of the old (now-internal) `BurlyContainer.phone` — this and
    /// `.watch(at:)` are the two named, device-shaped entry points; use
    /// `init(kind:at:)` directly only when the kind is a runtime value.
    public static func phone(
        at location: BurlyStoreLocation = .applicationDefault
    ) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .phone, at: location)
    }

    /// Watch store: working set only (§1 store shape). See `.phone(at:)`.
    public static func watch(
        at location: BurlyStoreLocation = .applicationDefault
    ) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .watch, at: location)
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
        try context.save()
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
        try context.save()
    }

    // MARK: - Routines

    public func createRoutine(_ routine: RoutineData) throws {
        guard try model(Routine.self, id: routine.id) == nil else {
            throw BurlyStoreError.duplicateID(routine.id)
        }

        let stored = Routine(
            id: routine.id,
            name: routine.name,
            orderIndex: routine.orderIndex,
            updatedAt: routine.updatedAt,
            archivedAt: routine.archivedAt
        )
        context.insert(stored)

        for item in routine.items {
            let storedItem = RoutineItem(
                id: item.id,
                exercise: try resolveExercise(item.exerciseID),
                order: item.order,
                defaultSetCount: item.defaultSetCount,
                restOverride: item.restOverride,
                note: item.note
            )
            context.insert(storedItem)
            stored.items.append(storedItem)
        }

        try context.save()
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
        try context.save()
    }

    public func deleteRoutine(id: UUID) throws {
        guard let routine = try model(Routine.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        context.delete(routine)
        try context.save()
    }

    public func updateRoutine(_ routine: RoutineData) throws {
        guard let stored = try model(Routine.self, id: routine.id) else {
            throw BurlyStoreError.notFound(routine.id)
        }

        // Resolve every item's exercise reference before mutating anything:
        // a rejected update must leave the stored routine untouched, not
        // half-replaced with its old items already deleted.
        let resolved = try routine.items.map { try resolveExercise($0.exerciseID) }

        stored.name = routine.name
        stored.orderIndex = routine.orderIndex
        // Store-maintained mutation metadata (m1-04 review): `updatedAt` is
        // set from the store's own clock, not copied from `routine.updatedAt`
        // — a caller (or a stale round-tripped DTO) cannot claim an edit
        // happened earlier or later than it actually did. See the protocol
        // doc on `updateRoutine`.
        stored.updatedAt = Date()
        // `archivedAt` is deliberately not assigned here — see the
        // protocol doc on `updateRoutine`.

        for item in stored.items {
            context.delete(item)
        }
        stored.items.removeAll()

        for (item, exercise) in zip(routine.items, resolved) {
            let storedItem = RoutineItem(
                id: item.id,
                exercise: exercise,
                order: item.order,
                defaultSetCount: item.defaultSetCount,
                restOverride: item.restOverride,
                note: item.note
            )
            context.insert(storedItem)
            stored.items.append(storedItem)
        }

        try context.save()
    }

    // MARK: - Sessions

    public func createSession(_ session: SessionData) throws {
        guard try model(Session.self, id: session.id) == nil else {
            throw BurlyStoreError.duplicateID(session.id)
        }

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

        for item in session.items {
            let storedItem = SessionItem(
                id: item.id,
                exercise: try resolveExercise(item.exerciseID),
                order: item.order
            )
            context.insert(storedItem)
            stored.items.append(storedItem)

            for set in item.sets {
                let storedSet = makeSetRecord(set)
                context.insert(storedSet)
                storedItem.sets.append(storedSet)
            }
        }

        try context.save()
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
        .map { $0.snapshot() }
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
        .map { $0.snapshot() }
    }

    public func logSet(_ set: SetRecordData, toSessionItem sessionItemID: UUID) throws {
        guard let item = try model(SessionItem.self, id: sessionItemID) else {
            throw BurlyStoreError.notFound(sessionItemID)
        }
        guard try model(SetRecord.self, id: set.id) == nil else {
            throw BurlyStoreError.duplicateID(set.id)
        }
        let storedSet = makeSetRecord(set)
        context.insert(storedSet)
        item.sets.append(storedSet)
        try context.save()
    }

    @discardableResult
    public func deleteSession(id: UUID) throws -> UUID? {
        guard let session = try model(Session.self, id: id) else {
            throw BurlyStoreError.notFound(id)
        }
        let workoutID = session.healthKitWorkoutID
        context.delete(session)
        try context.save()
        return workoutID
    }

    // MARK: - Last-performance digests

    public func lastPerformance(exerciseID: UUID) throws -> ExerciseLastPerformanceData? {
        try lastPerformanceModel(exerciseID: exerciseID)?.snapshot()
    }

    public func upsertLastPerformance(_ performance: ExerciseLastPerformanceData) throws {
        // §1: the phone derives digests from full history at push time and
        // never stores this entity — only a watch-kind store may write one.
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
        if let existing = try lastPerformanceModel(exerciseID: performance.exerciseID) {
            existing.performedAt = performance.performedAt
            existing.sets = performance.sets
        } else {
            context.insert(
                ExerciseLastPerformance(
                    exerciseID: performance.exerciseID,
                    performedAt: performance.performedAt,
                    sets: performance.sets
                )
            )
        }
        try context.save()
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
            .map { $0.snapshot() }
    }

    public func pruneDeliveredSessions(ackedIDs: [UUID]) throws {
        guard kind == .watch else {
            throw BurlyStoreError.operationRequiresWatchStore
        }
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
            context.delete(session)
        }
        try context.save()
    }

    // MARK: - Internals

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

    /// nil means "no exercise attached" (spec allows `exercise: Exercise?`).
    /// A non-nil id that isn't stored is a caller bug, not a nullable field.
    private func resolveExercise(_ id: UUID?) throws -> Exercise? {
        guard let id else { return nil }
        guard let exercise = try model(Exercise.self, id: id) else {
            throw BurlyStoreError.missingExercise(id)
        }
        return exercise
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
