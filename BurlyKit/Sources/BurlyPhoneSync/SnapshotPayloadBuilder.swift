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
import BurlyPersistence
import BurlySync

public enum SnapshotPayloadBuilder {
    /// Builds the §5 `snapshot` payload at `version` from current store
    /// truth: every non-archived exercise and routine.
    ///
    /// Archived exercises/routines are left out on purpose. §5 calls this a
    /// "whole-working-set replace" of what the watch actually uses to start
    /// and log workouts — the routine list (§2 Start) and the swap/add
    /// catalog picker (§2 mid-session edits) both already hide archived
    /// rows on the phone (`includingArchived: false` is exactly the
    /// picker-visibility flag both `exercises(includingArchived:)` and
    /// `routines(includingArchived:)` document) — and the watch never
    /// accumulates history (§1), so it has no symmetric reason to carry an
    /// archived routine's name forward the way a phone-side history row
    /// does. A `needsNaming` placeholder the watch just created and the
    /// phone hasn't merged yet is never archived, so it always rides along
    /// normally.
    public static func build(version: Int, from store: any BurlyStore) throws -> BurlySnapshotPayloadDTO {
        BurlySnapshotPayloadDTO(
            version: version,
            exercises: try store.exercises(includingArchived: false),
            routines: try store.routines(includingArchived: false)
        )
    }
}
