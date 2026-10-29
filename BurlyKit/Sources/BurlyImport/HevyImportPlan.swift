// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyImportPlan
//
// The preview/commit seam for spec §8's flow (task m7-02): "preview (N
// workouts, date range, exercises matched / new customs, dropped-data
// report) -> confirm -> import -> summary", with acceptance #4 "preview
// numbers match final import result exactly."
//
// `HevyCSVImporter.parse` describes the FILE. A preview has to describe the
// WRITE: the same export imported twice must preview "0 new" (spec §8
// acceptance #2's deterministic-UUID upsert), and an overlapping newer
// export must preview only the workouts the store does not have yet. So the
// plan is computed from the parse result plus what the store already holds
// (two `Set<UUID>` snapshots — this target deliberately has no
// BurlyPersistence edge, see Package.swift), and it carries the exact rows
// it will write. `apply` writes exactly those rows and nothing else, which
// is what makes "preview == result" true by construction rather than by two
// computations happening to agree.
//
// No HealthKit anywhere on this path (spec §8: "No HKWorkout writes for
// imports — Hevy already wrote those workouts to Health; writing again
// would double-count on the bus"; acceptance #3). BurlyImport does not link
// HealthKit at all, and every planned session's `healthKitWorkoutID` is
// forced to nil so an imported session can never claim a Health workout
// Burly did not write.
import BurlyCore
import Foundation

/// The numbers the preview screen shows. Every count describes what the
/// commit will write (or, for `alreadyImportedWorkoutCount`, deliberately
/// skip), never the raw file — the file-level drop report lives on
/// `HevyImportPlan.fileSummary` beside this.
public struct HevyImportPreview: Sendable, Equatable {
    /// Distinct workouts the file contains (after grouping rows by title +
    /// start time; malformed and cardio rows never form a workout).
    public let workoutsInFile: Int
    /// Workouts the commit will create.
    public let newWorkoutCount: Int
    /// Workouts in the file whose deterministic ID is already stored — a
    /// re-import or an overlapping export. Skipped, never duplicated.
    public let alreadyImportedWorkoutCount: Int
    /// Earliest to latest start across every workout in the file, so the
    /// user can check the time-zone assumption against dates they recognize
    /// even when nothing is new. `nil` only for a file with no workouts.
    public let fileDateRange: ClosedRange<Date>?
    /// Earliest to latest start across the workouts the commit will create.
    public let newWorkoutDateRange: ClosedRange<Date>?
    /// Distinct exercises the new workouts use that resolve to something
    /// Burly already knows: a catalog exercise (curated name or Hevy alias)
    /// or an exercise already in the store, such as a custom created by an
    /// earlier import of an overlapping file.
    public let exercisesMatched: Int
    /// Names of the custom (`origin: .hevyImport`) exercises the commit will
    /// create — spec §8: unmatched names are "never silently dropped". In
    /// first-use order.
    public let newCustomExerciseNames: [String]
    /// Sets inside the workouts the commit will create.
    public let setCount: Int

    public var newCustomExerciseCount: Int { newCustomExerciseNames.count }
    /// True when the store already holds every workout in the file.
    public var isNothingNew: Bool { newWorkoutCount == 0 }
}

public enum HevyImportPlanError: Error, Sendable, Equatable {
    /// A parsed session referenced an exercise ID that is neither in the
    /// catalog, nor among the parse's new custom exercises, nor already
    /// stored. `HevyCSVImporter` never produces one; this exists so a
    /// broken invariant fails the preview instead of failing halfway
    /// through the write.
    case unresolvedExercise(UUID)
}

public struct HevyImportPlan: Sendable, Equatable {
    /// Written first, in this order: catalog rows the store is missing
    /// (`origin: .curated`, exactly as `SeedLoader` would insert them), then
    /// new customs. Exercises precede sessions because `createSession`
    /// refuses an item whose exercise is not stored.
    public let exercisesToCreate: [ExerciseData]
    /// Written after `exercisesToCreate`, in file order.
    public let sessionsToCreate: [SessionData]
    public let preview: HevyImportPreview
    /// The parse's whole-file dropped-data accounting, passed through
    /// untouched: cardio rows, RPE values, superset grouping, failure/
    /// dropset markers, malformed rows with reasons, encoding damage and
    /// rows lost to an unterminated quote. Drops are a fact about the file,
    /// so they are reported the same whether or not its workouts are new.
    public let fileSummary: HevyImportSummary

    /// Builds the plan for `result` against the store's current contents.
    ///
    /// - Parameters:
    ///   - existingSessionIDs: The IDs among `result.sessions` that the
    ///     store already holds (a superset is fine — only membership is
    ///     asked).
    ///   - existingExerciseIDs: Every stored exercise ID, archived included
    ///     (an archived row still exists: `createExercise` would refuse its
    ///     ID, and history may still reference it).
    public static func make(
        result: HevyImportResult,
        catalog: CatalogSeed,
        existingSessionIDs: Set<UUID>,
        existingExerciseIDs: Set<UUID>
    ) throws -> HevyImportPlan {
        let newSessions = result.sessions
            .filter { existingSessionIDs.contains($0.id) == false }
            .map { session -> SessionData in
                var planned = session
                // Spec §8 / acceptance #3: an imported session never links
                // an HKWorkout. The importer already leaves this nil; the
                // plan guarantees it rather than trusting it.
                planned.healthKitWorkoutID = nil
                return planned
            }

        let customsByID = Dictionary(
            result.newExercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let catalogByID = Dictionary(
            catalog.exercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var referencedOrder: [UUID] = []
        var referenced = Set<UUID>()
        var setCount = 0
        for session in newSessions {
            for item in session.items {
                setCount += item.sets.count
                guard let exerciseID = item.exerciseID else { continue }
                if referenced.insert(exerciseID).inserted {
                    referencedOrder.append(exerciseID)
                }
            }
        }

        var catalogRowsToRestore: [ExerciseData] = []
        var customsToCreate: [ExerciseData] = []
        var matched = 0
        for exerciseID in referencedOrder {
            if existingExerciseIDs.contains(exerciseID) {
                matched += 1
            } else if let catalogExercise = catalogByID[exerciseID] {
                // A catalog match whose row the store lacks (a store the
                // bundled seed was never applied to). Still a match from
                // the user's point of view; the row is inserted the way
                // `SwiftDataStore.applyCatalogSeed` would insert it, and a
                // later seed application skips it by UUID.
                matched += 1
                catalogRowsToRestore.append(ExerciseData(
                    id: catalogExercise.id,
                    name: catalogExercise.name,
                    muscleGroups: catalogExercise.muscleGroups,
                    origin: .curated
                ))
            } else if let custom = customsByID[exerciseID] {
                customsToCreate.append(custom)
            } else {
                throw HevyImportPlanError.unresolvedExercise(exerciseID)
            }
        }

        let preview = HevyImportPreview(
            workoutsInFile: result.sessions.count,
            newWorkoutCount: newSessions.count,
            alreadyImportedWorkoutCount: result.sessions.count - newSessions.count,
            fileDateRange: dateRange(of: result.sessions),
            newWorkoutDateRange: dateRange(of: newSessions),
            exercisesMatched: matched,
            newCustomExerciseNames: customsToCreate.map(\.name),
            setCount: setCount
        )

        return HevyImportPlan(
            exercisesToCreate: catalogRowsToRestore + customsToCreate,
            sessionsToCreate: newSessions,
            preview: preview,
            fileSummary: result.summary
        )
    }

    private static func dateRange(of sessions: [SessionData]) -> ClosedRange<Date>? {
        guard let first = sessions.first else { return nil }
        var lower = first.startedAt
        var upper = first.startedAt
        for session in sessions.dropFirst() {
            lower = min(lower, session.startedAt)
            upper = max(upper, session.startedAt)
        }
        return lower...upper
    }
}

// MARK: - Commit

/// What `HevyImportPlan.apply` actually wrote. On success every count
/// equals its preview counterpart (`matches(_:)`); on a failure part-way,
/// the counts say exactly what landed before it.
public struct HevyImportOutcome: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public enum Stage: Sendable, Equatable {
            case exercise
            case session
        }
        public let stage: Stage
        /// The ID of the row whose write threw.
        public let id: UUID
        /// `String(describing:)` of the thrown error, for the summary screen.
        public let message: String
    }

    public let sessionsCreated: Int
    public let setsCreated: Int
    /// New `origin: .hevyImport` exercises written.
    public let customExercisesCreated: Int
    /// Missing catalog rows written alongside them (see
    /// `HevyImportPlan.exercisesToCreate`) — plumbing, not a preview number.
    public let catalogExercisesRestored: Int
    /// `nil` when the whole plan landed.
    public let failure: Failure?

    public var isComplete: Bool { failure == nil }

    /// True when every number the preview promised is the number written
    /// (spec §8 acceptance #4).
    public func matches(_ preview: HevyImportPreview) -> Bool {
        isComplete
            && sessionsCreated == preview.newWorkoutCount
            && setsCreated == preview.setCount
            && customExercisesCreated == preview.newCustomExerciseCount
    }
}

/// Walks a plan's writes one row graph at a time, so the phone can show
/// real progress ("12 of 40") and let the UI breathe between writes. The
/// order and stop-at-first-failure rule are `HevyImportPlan.apply`'s — that
/// method is just this cursor run to the end, so a stepped commit and a
/// one-shot commit cannot disagree.
public struct HevyImportCommitCursor: Sendable {
    public let plan: HevyImportPlan
    private var nextIndex = 0
    private var customs = 0
    private var restored = 0
    private var sessions = 0
    private var sets = 0
    private var failure: HevyImportOutcome.Failure?

    public init(plan: HevyImportPlan) {
        self.plan = plan
    }

    /// Exercise writes plus session writes.
    public var totalWrites: Int { plan.exercisesToCreate.count + plan.sessionsToCreate.count }
    public var completedWrites: Int { nextIndex }
    public var sessionsWritten: Int { sessions }
    public var isFinished: Bool { failure != nil || nextIndex >= totalWrites }

    public var outcome: HevyImportOutcome {
        HevyImportOutcome(
            sessionsCreated: sessions,
            setsCreated: sets,
            customExercisesCreated: customs,
            catalogExercisesRestored: restored,
            failure: failure
        )
    }

    /// Performs the next write; does nothing once `isFinished`.
    public mutating func writeNext(
        createExercise: (ExerciseData) throws -> Void,
        createSession: (SessionData) throws -> Void
    ) {
        guard isFinished == false else { return }
        let exerciseCount = plan.exercisesToCreate.count
        if nextIndex < exerciseCount {
            let exercise = plan.exercisesToCreate[nextIndex]
            do {
                try createExercise(exercise)
            } catch {
                failure = .init(stage: .exercise, id: exercise.id, message: String(describing: error))
                return
            }
            if exercise.origin == .hevyImport {
                customs += 1
            } else {
                restored += 1
            }
        } else {
            let session = plan.sessionsToCreate[nextIndex - exerciseCount]
            do {
                try createSession(session)
            } catch {
                failure = .init(stage: .session, id: session.id, message: String(describing: error))
                return
            }
            sessions += 1
            sets += session.items.reduce(0) { $0 + $1.sets.count }
        }
        nextIndex += 1
    }
}

extension HevyImportPlan {
    /// Writes exactly `exercisesToCreate`, then exactly `sessionsToCreate`,
    /// through the caller's store, stopping at the first write that throws.
    ///
    /// Takes the two writes as closures rather than a store so this target
    /// stays free of BurlyPersistence (the app passes `BurlyStore
    /// .createExercise` / `.createSession`, which commit one row graph per
    /// call). Stopping is safe to recover from: every ID is deterministic,
    /// so planning the same file again against the store as it now stands
    /// skips whatever already landed and writes only the rest — re-importing
    /// is idempotent.
    public func apply(
        createExercise: (ExerciseData) throws -> Void,
        createSession: (SessionData) throws -> Void
    ) -> HevyImportOutcome {
        var cursor = HevyImportCommitCursor(plan: self)
        while cursor.isFinished == false {
            cursor.writeNext(createExercise: createExercise, createSession: createSession)
        }
        return cursor.outcome
    }
}
