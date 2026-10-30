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
    /// truth: every non-archived routine and every exercise it references.
    ///
    /// Archived routines are left out on purpose. §5 calls this a
    /// "whole-working-set replace" of what the watch actually uses to start
    /// and log workouts — the routine list (§2 Start) and the swap/add
    /// catalog picker (§2 mid-session edits) both already hide archived
    /// rows on the phone. Picker visibility controls what users may newly
    /// choose; it does not invalidate an existing live routine item, so an
    /// archived exercise still referenced by a non-archived routine is sent
    /// with that routine. The watch must retain the reference rather than
    /// rendering an item with no exercise. The watch never
    /// accumulates history (§1), so it has no symmetric reason to carry an
    /// archived routine's name forward the way a phone-side history row
    /// does. A `needsNaming` placeholder the watch just created and the
    /// phone hasn't merged yet is never archived, so it always rides along
    /// normally.
    ///
    /// `settings` are read when the snapshot is built, like the store, so a
    /// push always carries the phone's current unit and rest default.
    @MainActor
    public static func build(
        version: Int,
        from store: any BurlyStore,
        settings: PhoneWatchSettings = PhoneWatchSettings()
    ) throws -> BurlySnapshotPayloadDTO {
        let routines = try store.routines(includingArchived: false)
        let referencedExerciseIDs = Set(routines.flatMap { $0.items.compactMap(\.exerciseID) })
        let exercises = try store.exercises(includingArchived: true).filter {
            $0.archivedAt == nil || referencedExerciseIDs.contains($0.id)
        }
        return BurlySnapshotPayloadDTO(
            version: version,
            exercises: exercises,
            routines: routines,
            displayUnit: settings.displayUnit,
            restDefault: settings.restDefault
        )
    }
}
