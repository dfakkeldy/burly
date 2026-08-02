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
//
// ## Never reset a monotonic identity (m4-04 review round 1, blocker 1)
//
// `latestSnapshotVersion` and `lastTransferGeneration` are the two facts §5
// requires to be strictly monotonic for the *lifetime of the phone*, not
// just within one process: a repeated generation aliases a live transfer
// with a stale one's late callback (`PhoneSyncMachine`'s own doc on
// `.snapshotTransferFinished`), and a regressed snapshot version makes the
// watch reject every push until enough catalog edits rebuild the line it
// already had. The first version of this file treated the primary state
// file like any other cache: unreadable or malformed → `try?` → fall back
// to `State()`. That is a **fail-open reset** of exactly the two values §5
// forbids resetting, and it is silent — nothing surfaces that it happened.
//
// The fix has two independent parts:
//
// 1. **A separate, append-only high-water-mark log** (`HighWaterMarkLog`
//    below), holding only `(version, generation)`, written on every
//    `save()` call — which always runs, per `PhoneSyncCoordinator.deliver
//    (_:)`, before any command produced by the same event executes,
//    including a `.transmitSnapshot` — so the log is durable *before* the
//    identity it names is ever handed to a transport. Appended, not
//    overwritten: if the latest line is torn by a crash mid-write, every
//    complete line before it still contributes to the max on the next
//    read, which a single overwritten record could not survive on its own.
//    Its own corruption is tolerated the same way — a line that fails to
//    parse, or parses to a negative value, is skipped rather than aborting
//    the read (see `HighWaterMarkLog.currentHighWater()`).
// 2. **Recovery is explicit, not silent.** When the primary state file is
//    missing, unreadable, or semantically invalid, `load()` still returns a
//    usable `PhoneSyncLoadResult` — every self-healing fact (acks, pending
//    confirmations, daily-push timing) resets to empty, exactly as before,
//    because the §5 protocol's own idempotency absorbs that loss — but
//    `latestSnapshotVersion`/`lastTransferGeneration` are restored from the
//    high-water log, never from a fresh zero, and `recoveredFromCorruption`
//    is `true` so `PhoneSyncCoordinator` can surface the event rather than
//    quietly proceeding as if nothing happened.
//
// ## Semantically-corrupt JSON is a thrown error, not a trap
//
// `PhoneSyncMachine.State.init` and `PendingIngest.init` use `precondition`
// to state their invariants (non-negative versions/ages) — appropriate for
// a machine whose own logic can never violate them, wrong for JSON read
// back from disk, which can say anything. `try?` around a call that can
// *trap* does not catch the trap; it terminates the process. `Snapshot
// .makeRuntimeState()` below is therefore a **throwing** validator: it
// checks every one of those invariants itself and throws
// `PhoneSyncStateCorruptionError` on the first violation, so a hand-edited
// or bit-flipped negative value is recoverable (falls into the same
// high-water-preserving path as an unreadable file) instead of fatal.
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

/// The result of `PhoneSyncStatePersisting.load()`: the runtime state to
/// resume with, and whether it is a **surfaced recovery** (blocker 1) — the
/// primary state was missing/unreadable/invalid and had to be reconstructed
/// from the high-water-mark log alone, rather than a clean load of what was
/// last saved.
public struct PhoneSyncLoadResult: Sendable, Equatable {
    public var runtimeState: PhoneSyncRuntimeState
    public var recoveredFromCorruption: Bool

    public init(runtimeState: PhoneSyncRuntimeState, recoveredFromCorruption: Bool) {
        self.runtimeState = runtimeState
        self.recoveredFromCorruption = recoveredFromCorruption
    }
}

/// Thrown by the throwing validators below instead of letting
/// `PhoneSyncMachine.State`'s own `precondition`s trap on data read back
/// from disk. Never thrown by production logic — only by a load path
/// reconstructing a `State` from untrusted JSON.
public enum PhoneSyncStateCorruptionError: Error, Equatable {
    case negativeSnapshotVersion(Int)
    case negativeTransferGeneration(Int)
    case negativeAckAge(sessionID: UUID, age: TimeInterval)
    case negativePendingAge(sessionID: UUID, age: TimeInterval)
}

/// Durably persists `PhoneSyncRuntimeState` across relaunch. Conformances
/// must be `Sendable`; `PhoneSyncCoordinator` (a `@MainActor` type) calls
/// through this on the main actor, but the type itself may be constructed
/// and handed around freely.
public protocol PhoneSyncStatePersisting: Sendable {
    /// The last saved state, or `nil` on genuine first launch (nothing ever
    /// saved, primary or high-water). See `PhoneSyncLoadResult`'s doc for
    /// what a non-`nil`, `recoveredFromCorruption: true` result means.
    func load() throws -> PhoneSyncLoadResult?

    /// Durably writes `state`, replacing whatever primary state was saved
    /// before. Must be atomic with respect to a crash mid-write — a torn
    /// write must never read back as a *different*, valid-looking state;
    /// failing to decode at all is the acceptable failure mode, silently
    /// reading stale-but-plausible data is not. Conformances must also
    /// durably record `state`'s monotonic identities (`latestSnapshotVersion`
    /// / `lastTransferGeneration`) in a form that survives the primary
    /// state becoming unreadable later (blocker 1) — see
    /// `FileBackedPhoneSyncStatePersisting`'s high-water log.
    func save(_ state: PhoneSyncRuntimeState) throws
}

/// The production conformer: one small JSON file for the full state,
/// written with `Data.write(options: .atomic)`, plus a separate append-only
/// high-water-mark log for the two identities that must never regress.
public final class FileBackedPhoneSyncStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let highWaterLog: HighWaterMarkLog

    /// - Parameters:
    ///   - url: the primary state file.
    ///   - highWaterURL: the append-only log; defaults to a sibling of
    ///     `url` (same directory, `.highwater.jsonl` in place of `url`'s
    ///     extension) so production call sites don't need to name a second
    ///     path. Tests may override it explicitly to inspect or corrupt it
    ///     directly.
    ///   - fileManager: injected for testability, matching every other
    ///     file-backed type in this package.
    public init(url: URL, highWaterURL: URL? = nil, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        let resolvedHighWaterURL = highWaterURL ?? url
            .deletingPathExtension()
            .appendingPathExtension("highwater.jsonl")
        self.highWaterLog = HighWaterMarkLog(url: resolvedHighWaterURL, fileManager: fileManager)
    }

    public func load() throws -> PhoneSyncLoadResult? {
        let highWater = highWaterLog.currentHighWater()

        guard fileManager.fileExists(atPath: url.path) else {
            // No primary file. Genuine first launch unless the high-water
            // log somehow holds a real record with no primary ever written
            // (defensive — should not happen in normal operation, but
            // "restore at-or-above the true high-water" must hold even
            // here).
            guard highWater != (0, 0) else { return nil }
            return PhoneSyncLoadResult(
                runtimeState: PhoneSyncRuntimeState(machineState: Self.stateRestoringHighWater(highWater)),
                recoveredFromCorruption: true
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            var runtime = try snapshot.makeRuntimeState()
            // Defensive max-merge even on a clean decode: `save()` always
            // writes the high-water log before the primary file (see this
            // file's header), so the primary should already be at or above
            // the log — this only ever matters if something wrote the
            // primary file through a path other than `save()`.
            runtime.machineState = Self.mergingHighWater(into: runtime.machineState, highWater)
            return PhoneSyncLoadResult(runtimeState: runtime, recoveredFromCorruption: false)
        } catch {
            // Primary unreadable (I/O) or semantically invalid
            // (`PhoneSyncStateCorruptionError` from `makeRuntimeState`) —
            // either way, a **surfaced** recovery: every self-healing fact
            // resets to empty, but the monotonic identities are restored
            // from the high-water log, never reused from zero.
            return PhoneSyncLoadResult(
                runtimeState: PhoneSyncRuntimeState(machineState: Self.stateRestoringHighWater(highWater)),
                recoveredFromCorruption: true
            )
        }
    }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        // Blocker 1: written before the primary save, and — because
        // `PhoneSyncCoordinator.deliver(_:)` always persists before
        // executing the commands an event produced — before any transmit
        // that could follow it. A crash between this line and the primary
        // write below still leaves the high-water log naming the identity
        // about to be used.
        try highWaterLog.append(
            version: state.machineState.latestSnapshotVersion,
            generation: state.machineState.lastTransferGeneration
        )

        let data = try JSONEncoder().encode(Snapshot(state))
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func stateRestoringHighWater(
        _ highWater: (version: Int, generation: Int)
    ) -> BurlyPhoneSyncMachine.State {
        mergingHighWater(into: BurlyPhoneSyncMachine.State(), highWater)
    }

    private static func mergingHighWater(
        into state: BurlyPhoneSyncMachine.State,
        _ highWater: (version: Int, generation: Int)
    ) -> BurlyPhoneSyncMachine.State {
        BurlyPhoneSyncMachine.State(
            ackAge: state.ackAge,
            lastObservedNow: state.lastObservedNow,
            pendingStoreConfirmations: state.pendingStoreConfirmations,
            latestSnapshotVersion: max(state.latestSnapshotVersion, highWater.version),
            lastTransferGeneration: max(state.lastTransferGeneration, highWater.generation),
            outstandingSnapshot: state.outstandingSnapshot
        )
    }

    /// The wire shape. Deliberately flat (two parallel dictionaries for
    /// `pendingStoreConfirmations` rather than a nested `Codable` type) so
    /// this file needs no `Codable` conformance added to
    /// `BurlySyncMachine`'s public types — that target is dependency-free
    /// and machine-type-seam-pure on purpose (see `PhoneSyncMachine.swift`'s
    /// module doc); this mapping stays entirely on the `BurlyPhoneSync`
    /// side of that seam.
    ///
    /// `internal`, not `private`/`fileprivate` — a deliberate test seam
    /// (`@testable import`) so `PhoneSyncStatePersistingTests` can drive
    /// `makeRuntimeState()`'s throwing validation directly, per corrupt
    /// field, without going through a full `load()` + high-water-recovery
    /// round trip for each one.
    struct Snapshot: Codable {
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

        /// A direct memberwise construction — declaring the initializer
        /// above suppresses Swift's automatic one, and tests need a way to
        /// build a *semantically invalid* `Snapshot` (a negative version, a
        /// negative age) directly, which `init(_:)` can never produce since
        /// `PhoneSyncMachine.State`'s own `precondition`s already refuse
        /// those values before a real `PhoneSyncRuntimeState` could exist.
        /// Test-only in spirit; kept undecorated (no `#if DEBUG`) since an
        /// unused internal initializer costs nothing in a release build.
        init(
            ackAge: [UUID: TimeInterval] = [:],
            lastObservedNow: Date? = nil,
            pendingRevisions: [UUID: Int] = [:],
            pendingAges: [UUID: TimeInterval] = [:],
            latestSnapshotVersion: Int,
            lastTransferGeneration: Int,
            outstandingSnapshotVersion: Int? = nil,
            outstandingSnapshotGeneration: Int? = nil,
            lastDailyPushAt: Date? = nil
        ) {
            self.ackAge = ackAge
            self.lastObservedNow = lastObservedNow
            self.pendingRevisions = pendingRevisions
            self.pendingAges = pendingAges
            self.latestSnapshotVersion = latestSnapshotVersion
            self.lastTransferGeneration = lastTransferGeneration
            self.outstandingSnapshotVersion = outstandingSnapshotVersion
            self.outstandingSnapshotGeneration = outstandingSnapshotGeneration
            self.lastDailyPushAt = lastDailyPushAt
        }

        /// Throwing, deliberately (blocker 1's second half): every field
        /// `BurlyPhoneSyncMachine.State`/`PendingIngest`'s own
        /// `precondition`s would otherwise trap on is checked here first,
        /// so a semantically-corrupt file (a negative age, a negative
        /// version — a hand edit, a bit flip) throws a catchable
        /// `PhoneSyncStateCorruptionError` instead of terminating the
        /// process. `load()` catches this the same way it catches a
        /// decode/IO failure.
        func makeRuntimeState() throws -> PhoneSyncRuntimeState {
            guard latestSnapshotVersion >= 0 else {
                throw PhoneSyncStateCorruptionError.negativeSnapshotVersion(latestSnapshotVersion)
            }
            guard lastTransferGeneration >= 0 else {
                throw PhoneSyncStateCorruptionError.negativeTransferGeneration(lastTransferGeneration)
            }
            for (id, age) in ackAge where age < 0 {
                throw PhoneSyncStateCorruptionError.negativeAckAge(sessionID: id, age: age)
            }
            for (id, age) in pendingAges where age < 0 {
                throw PhoneSyncStateCorruptionError.negativePendingAge(sessionID: id, age: age)
            }

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

/// The append-only high-water-mark log (blocker 1): one line per `save()`
/// call, `{"version":N,"generation":M}\n`, appended via `FileHandle` rather
/// than read-modify-rewrite — a crash mid-append can only corrupt the last
/// line, never an earlier one, which is the whole point (a single
/// atomically-overwritten record has no earlier line to fall back on if
/// *its* one write is the one that's damaged).
///
/// `currentHighWater()` tolerates the log's own corruption: a line that
/// fails to parse, or parses to a negative value, is skipped rather than
/// aborting the read, and the result is the max of every field across every
/// line that *did* parse. If every line is corrupt (a double failure far
/// rarer than either file corrupting alone), this degrades to `(0, 0)` —
/// the same starting point a genuine first launch has — rather than
/// throwing; there is no more truth to recover at that point; both durable
/// records of it disagree with everything.
///
/// Compacted opportunistically once the line count crosses a small bound,
/// via the same atomic-write guarantee the primary state file uses, so the
/// log never grows without limit across years of real usage.
private struct HighWaterMarkLog {
    private let url: URL
    private let fileManager: FileManager
    private let compactionThreshold = 200

    private struct Record: Codable {
        var version: Int
        var generation: Int
    }

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    func currentHighWater() -> (version: Int, generation: Int) {
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return (0, 0) }
        var maxVersion = 0
        var maxGeneration = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let record = try? JSONDecoder().decode(Record.self, from: Data(line)),
                record.version >= 0, record.generation >= 0
            else { continue }
            maxVersion = max(maxVersion, record.version)
            maxGeneration = max(maxGeneration, record.generation)
        }
        return (maxVersion, maxGeneration)
    }

    func append(version: Int, generation: Int) throws {
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let lineCount = currentLineCount()
        if lineCount >= compactionThreshold {
            // Compact first: one line carrying the max seen so far
            // (including this call's own values), written atomically —
            // the same non-torn guarantee the primary state file uses.
            // Worst case on a crash mid-compaction is the old, larger file
            // surviving intact; never a torn one.
            let current = currentHighWater()
            let compacted = Record(
                version: max(current.version, version),
                generation: max(current.generation, generation)
            )
            var line = try JSONEncoder().encode(compacted)
            line.append(UInt8(ascii: "\n"))
            try line.write(to: url, options: .atomic)
            return
        }

        if fileManager.fileExists(atPath: url.path) == false {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        var line = try JSONEncoder().encode(Record(version: version, generation: generation))
        line.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func currentLineCount() -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.count(where: { $0 == UInt8(ascii: "\n") })
    }
}

/// An in-memory conformer for tests and previews — "persists" only for the
/// lifetime of the instance, and never corrupts, so `recoveredFromCorruption`
/// is always `false`.
public final class InMemoryPhoneSyncStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private var stored: PhoneSyncRuntimeState?

    public init(_ initial: PhoneSyncRuntimeState? = nil) {
        self.stored = initial
    }

    public func load() throws -> PhoneSyncLoadResult? {
        stored.map { PhoneSyncLoadResult(runtimeState: $0, recoveredFromCorruption: false) }
    }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        stored = state
    }
}
