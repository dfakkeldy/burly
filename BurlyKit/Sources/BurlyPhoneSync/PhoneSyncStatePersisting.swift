// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — PhoneSyncStatePersisting
//
// Binding contract item 5 (SyncMachineBinding.swift): "the state carrying a
// new ack is persisted before (or atomically with) executing the
// publishDigest it produced, so a crash between them re-publishes on the
// next event instead of acking from a state that no longer exists." That
// requires `PhoneSyncMachine.State` to actually survive a relaunch, not
// merely persist "logically" for the duration of one process — and the
// house rules for this task forbid a schema change, so this cannot be a new
// `@Model` beside `BurlySchemaV1`.
//
// So it is a small, independent JSON file next to (not inside) the
// SwiftData store: a plain `Codable` mirror of `PhoneSyncMachine.State`,
// written atomically. `State`'s own stored properties are `fileprivate(set)`
// (readable from anywhere, mutable only from within
// `PhoneSyncMachine.swift`), but its memberwise initializer is public and
// takes every field, so this file can read a full snapshot out and rebuild
// an equal `State` back in without needing any access this module doesn't
// already have.
//
// `lastDailyPushAt` rides along in the same file even though it is not part
// of `PhoneSyncMachine.State` at all — it is `PhoneSyncCoordinator`'s own
// bookkeeping for the §5 daily push trigger (see that type's doc), and
// folding it into this one small save/load pair is simpler than a second,
// parallel persistence mechanism for one `Date?`.
import Foundation
import BurlySync
import BurlySyncMachine

/// Everything `PhoneSyncCoordinator` needs to survive a relaunch: the
/// protocol machine's own state, plus the coordinator's daily-push
/// bookkeeping.
public struct PhoneSyncRuntimeState: Sendable, Equatable {
    public var machineState: BurlyPhoneSyncMachine.State
    public var lastDailyPushAt: Date?

    public init(
        machineState: BurlyPhoneSyncMachine.State = BurlyPhoneSyncMachine.State(),
        lastDailyPushAt: Date? = nil
    ) {
        self.machineState = machineState
        self.lastDailyPushAt = lastDailyPushAt
    }
}

/// Durably persists `PhoneSyncRuntimeState` across relaunch. Conformances
/// must be `Sendable`; `PhoneSyncCoordinator` (an actor) calls through this
/// on its own executor, but the type itself may be constructed and handed
/// around freely.
public protocol PhoneSyncStatePersisting: Sendable {
    /// The last saved state, or `nil` on first launch (nothing saved yet).
    func load() throws -> PhoneSyncRuntimeState?

    /// Durably writes `state`, replacing whatever was saved before. Must be
    /// atomic with respect to a crash mid-write — a torn write must never
    /// read back as a *different*, valid-looking state; failing to decode
    /// at all (and falling back to a fresh state) is the acceptable failure
    /// mode, silently reading stale-but-plausible data is not.
    func save(_ state: PhoneSyncRuntimeState) throws
}

/// The production conformer: one small JSON file, written with
/// `Data.write(options: .atomic)` — the same "torn write is impossible,
/// only a clean old-or-new version is ever on disk" guarantee `.atomic`
/// gives any other single-file save, and the standard way to get it without
/// hand-rolling a temp-file-plus-rename dance.
public final class FileBackedPhoneSyncStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> PhoneSyncRuntimeState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Snapshot.self, from: data).makeRuntimeState()
    }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        let data = try JSONEncoder().encode(Snapshot(state))
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    /// The wire shape. Deliberately flat (two parallel dictionaries for
    /// `pendingStoreConfirmations` rather than a nested `Codable` type) so
    /// this file needs no `Codable` conformance added to
    /// `BurlySyncMachine`'s public types — that target is dependency-free
    /// and machine-type-seam-pure on purpose (see `PhoneSyncMachine.swift`'s
    /// module doc); this mapping stays entirely on the `BurlyPhoneSync`
    /// side of that seam.
    private struct Snapshot: Codable {
        var ackAge: [UUID: TimeInterval]
        var lastObservedNow: Date?
        var pendingRevisions: [UUID: Int]
        var pendingAges: [UUID: TimeInterval]
        var latestSnapshotVersion: Int
        var lastTransferGeneration: Int
        var outstandingSnapshotVersion: Int?
        var outstandingSnapshotGeneration: Int?
        var lastDailyPushAt: Date?

        init(_ runtime: PhoneSyncRuntimeState) {
            let state = runtime.machineState
            ackAge = state.ackAge
            lastObservedNow = state.lastObservedNow
            pendingRevisions = state.pendingStoreConfirmations.mapValues(\.revision)
            pendingAges = state.pendingStoreConfirmations.mapValues(\.age)
            latestSnapshotVersion = state.latestSnapshotVersion
            lastTransferGeneration = state.lastTransferGeneration
            outstandingSnapshotVersion = state.outstandingSnapshot?.version
            outstandingSnapshotGeneration = state.outstandingSnapshot?.generation
            lastDailyPushAt = runtime.lastDailyPushAt
        }

        func makeRuntimeState() -> PhoneSyncRuntimeState {
            var pending: [UUID: BurlyPhoneSyncMachine.PendingIngest] = [:]
            for (id, revision) in pendingRevisions {
                pending[id] = BurlyPhoneSyncMachine.PendingIngest(
                    revision: revision,
                    age: pendingAges[id] ?? 0
                )
            }
            let outstanding: BurlyPhoneSyncMachine.SnapshotTransfer?
            if let version = outstandingSnapshotVersion, let generation = outstandingSnapshotGeneration {
                outstanding = BurlyPhoneSyncMachine.SnapshotTransfer(version: version, generation: generation)
            } else {
                outstanding = nil
            }
            let machineState = BurlyPhoneSyncMachine.State(
                ackAge: ackAge,
                lastObservedNow: lastObservedNow,
                pendingStoreConfirmations: pending,
                latestSnapshotVersion: latestSnapshotVersion,
                lastTransferGeneration: lastTransferGeneration,
                outstandingSnapshot: outstanding
            )
            return PhoneSyncRuntimeState(machineState: machineState, lastDailyPushAt: lastDailyPushAt)
        }
    }
}

/// An in-memory conformer for tests and previews — "persists" only for the
/// lifetime of the instance. `final class` rather than a value type since
/// every production and test caller shares one instance across calls the
/// same way a file on disk is shared; the single stored property is only
/// ever touched from `PhoneSyncCoordinator`'s own actor isolation, which is
/// what makes the `@unchecked Sendable` honest here (no lock needed because
/// nothing outside that one serialized caller ever reaches it).
public final class InMemoryPhoneSyncStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private var stored: PhoneSyncRuntimeState?

    public init(_ initial: PhoneSyncRuntimeState? = nil) {
        self.stored = initial
    }

    public func load() throws -> PhoneSyncRuntimeState? { stored }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        stored = state
    }
}
