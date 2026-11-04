// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — SnapshotPayloadBuilder
//
// `SyncMachineBinding.swift`'s command-mapping doc, on `.transmitSnapshot`:
// "build the full catalog+routine payload at that version from store truth,
// transfer it." That construction needs `BurlyStore`, so it belongs here,
// one layer above the machine/wire seam — not in m4-03's transport adapter,
// which is deliberately app/domain-agnostic (its own brief: "payload kinds
// injected, no Burly domain imports").
import Foundation
import BurlyCore
import BurlyPersistence
import BurlySync

/// The phone Settings rows the watch follows (schema 2). They live in the
/// phone app's preferences, not the store, so the host app supplies them.
public struct PhoneWatchSettings: Sendable, Equatable {
    public var displayUnit: WeightUnit
    /// Clamped onto §3's grid, like every other rest value.
    public var restDefault: TimeInterval

    public init(
        displayUnit: WeightUnit = .kilograms,
        restDefault: TimeInterval = RestDuration.globalDefault
    ) {
        self.displayUnit = displayUnit
        self.restDefault = RestDuration.clamped(restDefault)
    }
}

public enum SnapshotPayloadBuilder {
    /// Builds the §5 `snapshot` payload at `version` from current store
    /// truth: every non-archived routine and the whole exercise catalog,
    /// archived rows included.
    ///
    /// Archived routines are left out on purpose. §5 calls this a
    /// "whole-working-set replace" of what the watch actually uses to start
    /// and log workouts, and the routine list (§2 Start) hides archived
    /// routines. The watch never accumulates history (§1), so it has no
    /// reason to carry an archived routine's name forward the way a
    /// phone-side history row does; the replace deletes it there.
    ///
    /// Exercises are the opposite: §5's snapshot is the "full catalog", and
    /// an archived exercise travels with its `archivedAt`. That is how an
    /// archive reaches the watch. The watch's replace updates only the
    /// exercises a payload names (a placeholder the watch created and the
    /// phone has not ingested yet is in no snapshot, and must survive it),
    /// so an exercise left out would keep its old, unarchived copy there
    /// and stay in the swap/add picker. That covers both phone archives:
    /// the catalog's "Archive exercise" and the naming queue's merge, which
    /// archives the placeholder (§6). The phone store has no way to delete
    /// an exercise (§1), so every exercise the watch was ever sent is in
    /// every later snapshot. Archiving only hides an exercise from the
    /// picker: a live routine item or a session in flight that already
    /// names it still resolves it.
    ///
    /// `settings` are read when the snapshot is built, like the store, so a
    /// push always carries the phone's current unit and rest default.
    @MainActor
    public static func build(
        version: Int,
        from store: any BurlyStore,
        settings: PhoneWatchSettings = PhoneWatchSettings()
    ) throws -> BurlySnapshotPayloadDTO {
        let workingSet = try WatchWorkingSet(from: store)
        return BurlySnapshotPayloadDTO(
            version: version,
            exercises: workingSet.catalog,
            routines: workingSet.routines,
            displayUnit: settings.displayUnit,
            restDefault: settings.restDefault
        )
    }
}

/// What a snapshot built from the store right now would carry, plus the
/// narrower exercise set the digest may mention.
///
/// The snapshot is the full catalog (`catalog`): every exercise, archived
/// ones included, so an archive reaches the watch picker. The digest is
/// bounded to exercises the watch can still show (`exercises`: non-archived,
/// plus archived ones a live routine still uses). An archived exercise no
/// live routine uses has no ghost row to update, so leaving it out of the
/// digest is how the 48 KB bound stays about the working set, not retired
/// names. Routines are the same in both payloads: non-archived only.
struct WatchWorkingSet {
    let routines: [RoutineData]
    /// Every stored exercise, archived included — what the snapshot sends.
    let catalog: [ExerciseData]
    /// Exercises the watch can start or add: the digest's working set.
    let exercises: [ExerciseData]

    @MainActor
    init(from store: any BurlyStore) throws {
        routines = try store.routines(includingArchived: false)
        catalog = try store.exercises(includingArchived: true)
        let referencedExerciseIDs = Set(routines.flatMap { $0.items.compactMap(\.exerciseID) })
        exercises = catalog.filter {
            $0.archivedAt == nil || referencedExerciseIDs.contains($0.id)
        }
    }

    /// Exercises a routine on the watch starts with (§2 Start), as opposed
    /// to ones only reachable through the mid-session catalog picker.
    var routineExerciseIDs: Set<UUID> {
        Set(routines.flatMap { $0.items.compactMap(\.exerciseID) })
    }
}
