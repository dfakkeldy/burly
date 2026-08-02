// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import BurlyCore
import BurlySync

/// The persisted protocol facts owned by the watch coordinator.  The outbox
/// itself is the set of logged watch sessions; this journal remembers the
/// facts which cannot be reconstructed from that working set.
public struct WatchSyncStateData: Sendable, Equatable, Codable {
    public var lastAppliedSnapshotVersion: Int?
    public var lastAckedSessionIDs: Set<UUID>

    public init(
        lastAppliedSnapshotVersion: Int? = nil,
        lastAckedSessionIDs: Set<UUID> = []
    ) {
        self.lastAppliedSnapshotVersion = lastAppliedSnapshotVersion
        self.lastAckedSessionIDs = lastAckedSessionIDs
    }
}

/// Runtime-only operations for the watch endpoint.  `BurlyStore` remains the
/// public domain-store surface; this narrower protocol is the §5 executor
/// seam and is implemented only by the watch SwiftData store.
public protocol WatchSyncStore: AnyObject {
    func watchSyncState() throws -> WatchSyncStateData
    func loggedSessionsAwaitingAck() throws -> [SessionData]
    func replaceWatchWorkingSet(_ payload: BurlySnapshotPayloadDTO) throws
    func applyWatchDigest(_ payload: BurlyDigestPayloadDTO) throws
    func watchOutboxPayload(sessionID: UUID) throws -> BurlySessionPayloadDTO?
}

extension SwiftDataStore: WatchSyncStore {
    public func watchSyncState() throws -> WatchSyncStateData {
        guard kind == .watch else { throw BurlyStoreError.operationRequiresWatchStore }
        return try watchSyncJournal()?.decodedState() ?? WatchSyncStateData()
    }

    /// Whole-working-set replacement. Exercises are archive-only and may be
    /// referenced by retained local sessions, so exercises absent from a
    /// snapshot are retained; routines are replica working-set rows and are
    /// removed when absent.
    public func replaceWatchWorkingSet(_ payload: BurlySnapshotPayloadDTO) throws {
        guard kind == .watch else { throw BurlyStoreError.operationRequiresWatchStore }
        let current = try watchSyncState()
        guard current.lastAppliedSnapshotVersion.map({ payload.version > $0 }) ?? true else { return }
        guard Set(payload.exercises.map(\.id)).count == payload.exercises.count,
              Set(payload.routines.map(\.id)).count == payload.routines.count else {
            throw BurlyStoreError.duplicateID(UUID())
        }

        let exerciseIDs = Set(payload.exercises.map(\.id))
        for routine in payload.routines {
            for item in routine.items where item.exerciseID.map({ exerciseIDs.contains($0) }) == false {
                throw BurlyStoreError.missingExercise(item.exerciseID ?? UUID())
            }
        }

        for exercise in payload.exercises {
            if let stored = try model(Exercise.self, id: exercise.id) {
                stored.name = exercise.name
                stored.muscleGroups = exercise.muscleGroups
                stored.origin = exercise.origin
                stored.needsNaming = exercise.needsNaming
                stored.archivedAt = exercise.archivedAt
            } else {
                context.insert(Exercise(id: exercise.id, name: exercise.name, muscleGroups: exercise.muscleGroups, origin: exercise.origin, needsNaming: exercise.needsNaming, archivedAt: exercise.archivedAt))
            }
        }
        let incomingRoutineIDs = Set(payload.routines.map(\.id))
        for routine in try context.fetch(FetchDescriptor<Routine>()) where !incomingRoutineIDs.contains(routine.id) {
            context.delete(routine)
        }
        for routine in payload.routines {
            let stored = try model(Routine.self, id: routine.id)
            let resolved = try preflightRoutineItems(routine, ownedBy: stored)
            let target = stored ?? Routine(id: routine.id, name: routine.name, orderIndex: routine.orderIndex, updatedAt: routine.updatedAt, archivedAt: routine.archivedAt)
            if stored == nil { context.insert(target) }
            target.name = routine.name
            target.orderIndex = routine.orderIndex
            target.updatedAt = routine.updatedAt
            target.archivedAt = routine.archivedAt
            replaceRoutineItems(of: target, with: routine.items, resolved: resolved)
        }
        var next = current
        next.lastAppliedSnapshotVersion = payload.version
        try stageWatchSyncState(next)
        try commit()
    }

    /// The production digest path. Last performance, pruning, and the ack
    /// replay guard are staged before this one commit; no callback observes a
    /// partially applied digest.
    public func applyWatchDigest(_ payload: BurlyDigestPayloadDTO) throws {
        guard kind == .watch else { throw BurlyStoreError.operationRequiresWatchStore }
        try validateLastPerformance(payload.lastPerformance)
        for entry in payload.lastPerformance { try upsert(entry) }
        try prune(ackedIDs: payload.ackedSessionIDs)
        var next = try watchSyncState()
        next.lastAckedSessionIDs = Set(payload.ackedSessionIDs)
        try stageWatchSyncState(next)
        try commit()
    }

    public func watchOutboxPayload(sessionID: UUID) throws -> BurlySessionPayloadDTO? {
        guard kind == .watch else { throw BurlyStoreError.operationRequiresWatchStore }
        guard let session = try session(id: sessionID), session.state == .logged else { return nil }
        let referenced = Set(session.items.compactMap(\.exerciseID))
        let placeholders = try referenced.compactMap { id -> ExerciseData? in
            guard let exercise = try exercise(id: id), exercise.needsNaming else { return nil }
            return exercise
        }
        return BurlySessionPayloadDTO(session: session, needsNamingExercises: placeholders)
    }

    private func watchSyncJournal() throws -> WatchSyncJournal? {
        let key = WatchSyncJournal.singletonKey
        var descriptor = FetchDescriptor<WatchSyncJournal>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func stageWatchSyncState(_ state: WatchSyncStateData) throws {
        let payload = try JSONEncoder().encode(state)
        if let journal = try watchSyncJournal() {
            journal.payload = payload
        } else {
            context.insert(WatchSyncJournal(payload: payload))
        }
    }
}

private extension WatchSyncJournal {
    func decodedState() throws -> WatchSyncStateData {
        try JSONDecoder().decode(WatchSyncStateData.self, from: payload)
    }
}
