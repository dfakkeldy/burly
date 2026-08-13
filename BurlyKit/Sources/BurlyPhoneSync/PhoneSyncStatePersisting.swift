// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — PhoneSyncStatePersisting
//
// Binding contract item 5 requires the state carrying a new ack to be
// durable before its commands execute. Phone sync therefore uses one
// append-only JSON-lines journal beside the SwiftData store. Every line is
// `{seq, fullRuntimeState, checksum}`: a torn or corrupted append cannot
// turn into a different valid state, and earlier complete lines remain
// available.
//
// `load()` takes the full runtime state from the newest checksum-valid line,
// except for the two lifetime-monotonic identities. It takes
// `latestSnapshotVersion` and `lastTransferGeneration` independently as the
// maximum across every valid line. This is the journal's reason to exist:
// losing the newest line must never reuse a transfer generation or regress
// below a snapshot version the watch has already adopted.
//
// The file's existence is the complete recovery boundary. Absent means
// first launch; present with no valid record is unrecoverable. Compaction
// and an explicit re-pair reset both use the same atomic whole-file replace
// with one checksum-valid full-state line. The former folds in the identity
// maxima; the latter deliberately starts a new identity domain.
//
// A one-time migration can be configured with the legacy full-state and
// high-water-log URLs. Only while the journal is absent, the legacy loader
// reconstructs exactly the state the two-file implementation would have
// loaded, seeds the journal atomically, and removes the legacy files.
import Foundation
import Darwin
import BurlySync
import BurlySyncMachine

/// m4-04 review round 2, finding 2 + round 3, §2 — see this file's header.
/// The single **inclusive** ceiling on `latestSnapshotVersion` and
/// `lastTransferGeneration`, enforced identically at every boundary this
/// file owns:
///
/// - **Read**: every checksum-valid journal record is also semantically
///   validated by `Snapshot.makeRuntimeState()`.
/// - **Write** (round 3, §2): `save(_:)` — in every conformer — throws
///   `PhoneSyncIdentityOverflowError` *before* appending anything when the
///   state to persist carries a value
///   above it. Read-side-only enforcement left a one-relaunch window: a
///   state at exactly the ceiling incremented to ceiling+1, was persisted
///   AND transmitted, and only the *next* relaunch rejected it — restoring
///   the prior value and re-using ceiling+1 on the following push.
///   Refusing at save time means an out-of-range identity can neither
///   reach disk nor (because `PhoneSyncCoordinator` always persists before
///   executing an event's commands) ever reach the transport.
///
/// The valid range everywhere is `0...maximumPhoneSyncIdentity`, inclusive:
/// a persisted value exactly at the ceiling loads cleanly; the *increment
/// past* it is what fails, as a thrown domain error — the same shape as
/// `SwiftDataStore.applyPhoneEdit`'s revision-overflow guard.
public let maximumPhoneSyncIdentity = 1_000_000_000

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
/// resume with, and whether invalid journal data was skipped to recover it.
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
    /// m4-04 review round 2, finding 2 — see this file's header.
    case snapshotVersionTooLarge(Int)
    case negativeTransferGeneration(Int)
    /// m4-04 review round 2, finding 2 — see this file's header.
    case transferGenerationTooLarge(Int)
    case negativeAckAge(sessionID: UUID, age: TimeInterval)
    case negativePendingAge(sessionID: UUID, age: TimeInterval)
}

/// Thrown by `save(_:)` (m4-04 review round 3, §2 — see
/// `maximumPhoneSyncIdentity`'s doc): the state to persist carries a
/// monotonic identity outside `0...maximumPhoneSyncIdentity`. A domain
/// error, not a trap, and thrown *before* any byte is written — neither
/// no journal record ever holds an out-of-range value, and
/// `PhoneSyncCoordinator`'s persist-before-execute ordering means the
/// transport never sees one either.
public enum PhoneSyncIdentityOverflowError: Error, Equatable {
    case snapshotVersionOutOfRange(Int)
    case transferGenerationOutOfRange(Int)
}

/// Round 3, §2 — the shared write-path bound check every
/// `PhoneSyncStatePersisting` conformer's `save(_:)` must apply (see that
/// requirement's doc). Free function so in-package conformers cannot drift
/// from each other on the bound or its inclusivity.
public func validatePhoneSyncIdentityBounds(_ state: PhoneSyncRuntimeState) throws {
    let version = state.machineState.latestSnapshotVersion
    guard version >= 0, version <= maximumPhoneSyncIdentity else {
        throw PhoneSyncIdentityOverflowError.snapshotVersionOutOfRange(version)
    }
    let generation = state.machineState.lastTransferGeneration
    guard generation >= 0, generation <= maximumPhoneSyncIdentity else {
        throw PhoneSyncIdentityOverflowError.transferGenerationOutOfRange(generation)
    }
}

/// Thrown by `load()` when the journal exists but contains zero valid lines.
/// This is deliberately distinct from first launch, where the file is absent.
public struct PhoneSyncStateUnrecoverableError: Error, Equatable {
    public init() {}
}

/// Durably persists `PhoneSyncRuntimeState` across relaunch. Conformances
/// must be `Sendable`; `PhoneSyncCoordinator` (a `@MainActor` type) calls
/// through this on the main actor, but the type itself may be constructed
/// and handed around freely.
public protocol PhoneSyncStatePersisting: Sendable {
    /// The newest checksum-valid state, or `nil` when the journal is absent
    /// on first launch. A present journal with no valid lines throws
    /// `PhoneSyncStateUnrecoverableError`.
    func load() throws -> PhoneSyncLoadResult?

    /// Durably appends `state` as one checksum-protected full-state record.
    /// A torn append must leave older valid records loadable. Loads take the
    /// full state from the newest valid record and both monotonic identities
    /// as the maxima across every valid record.
    ///
    /// Round 3, §2: conformances must **refuse** (throw
    /// `PhoneSyncIdentityOverflowError`, via
    /// `validatePhoneSyncIdentityBounds(_:)`) a state whose
    /// `latestSnapshotVersion` or `lastTransferGeneration` falls outside
    /// `0...maximumPhoneSyncIdentity`, before writing anything — the write
    /// path is where the ceiling actually binds, since the coordinator
    /// persists before it transmits.
    func save(_ state: PhoneSyncRuntimeState) throws

    /// Atomically replaces the journal with one record for a deliberately
    /// fresh identity domain. This uses the same whole-file replacement
    /// primitive as compaction. On failure, the old journal remains intact.
    func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws
}

/// The production conformer: one append-only checksum-protected JSON-lines
/// journal containing the complete runtime state in every record.
public final class FileBackedPhoneSyncStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let legacyStateURL: URL?
    private let legacyHighWaterURL: URL?
    private let lock = NSLock()
    private let compactionLineLimit: Int

    /// - Parameters:
    ///   - url: the single journal file.
    ///   - legacyStateURL: the old full-state sidecar, read only when the
    ///     journal is absent and removed after successful migration.
    ///   - legacyHighWaterURL: the old high-water log paired with
    ///     `legacyStateURL`.
    ///   - fileManager: injected for testability.
    public init(
        url: URL,
        legacyStateURL: URL? = nil,
        legacyHighWaterURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        self.legacyStateURL = legacyStateURL
        self.legacyHighWaterURL = legacyHighWaterURL
        self.compactionLineLimit = 200
    }

    public func load() throws -> PhoneSyncLoadResult? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        try validatePhoneSyncIdentityBounds(state)
        lock.lock()
        defer { lock.unlock() }

        let read = try readJournal()
        if read.fileExists, read.valid.isEmpty {
            throw PhoneSyncStateUnrecoverableError()
        }

        let nextSequence: Int
        if let maximumSequence = read.valid.map(\.record.seq).max(), maximumSequence < Int.max {
            nextSequence = maximumSequence + 1
        } else {
            nextSequence = 0
        }

        if read.nonemptyLineCount >= compactionLineLimit || nextSequence == 0 && read.valid.isEmpty == false {
            let compacted = Self.replacingIdentities(
                in: state,
                latestSnapshotVersion: max(
                    state.machineState.latestSnapshotVersion,
                    read.maximumSnapshotVersion
                ),
                lastTransferGeneration: max(
                    state.machineState.lastTransferGeneration,
                    read.maximumTransferGeneration
                )
            )
            try replaceJournal(with: compacted)
        } else {
            try appendRecord(try Record(seq: nextSequence, runtimeState: state))
        }
    }

    public func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {
        try validatePhoneSyncIdentityBounds(state)
        lock.lock()
        defer { lock.unlock() }
        try replaceJournal(with: state)
    }

    private func loadLocked() throws -> PhoneSyncLoadResult? {
        if fileManager.fileExists(atPath: url.path) == false {
            return try migrateLegacyIfAvailable()
        }

        let read = try readJournal()
        guard let newest = read.valid.max(by: {
            $0.record.seq == $1.record.seq
                ? $0.lineIndex < $1.lineIndex
                : $0.record.seq < $1.record.seq
        }) else {
            throw PhoneSyncStateUnrecoverableError()
        }
        let runtime = Self.replacingIdentities(
            in: newest.runtimeState,
            latestSnapshotVersion: read.maximumSnapshotVersion,
            lastTransferGeneration: read.maximumTransferGeneration
        )
        return PhoneSyncLoadResult(
            runtimeState: runtime,
            recoveredFromCorruption: read.invalidLineCount > 0
        )
    }

    private func migrateLegacyIfAvailable() throws -> PhoneSyncLoadResult? {
        guard let legacyStateURL else { return nil }
        let legacy = LegacyTwoFilePhoneSyncStateLoader(
            stateURL: legacyStateURL,
            highWaterURL: legacyHighWaterURL ?? legacyStateURL
                .deletingPathExtension()
                .appendingPathExtension("highwater.jsonl"),
            fileManager: fileManager
        )
        guard let loaded = try legacy.load() else { return nil }
        try replaceJournal(with: loaded.runtimeState)
        if legacyStateURL != url { try? fileManager.removeItem(at: legacyStateURL) }
        if let legacyHighWaterURL, legacyHighWaterURL != url {
            try? fileManager.removeItem(at: legacyHighWaterURL)
        } else {
            let derived = legacyStateURL.deletingPathExtension().appendingPathExtension("highwater.jsonl")
            if derived != url { try? fileManager.removeItem(at: derived) }
        }
        return loaded
    }

    private func appendRecord(_ record: Record) throws {
        try createParentDirectoryIfNeeded()
        var line = try Self.makeEncoder().encode(record)
        line.append(UInt8(ascii: "\n"))
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let written = try line.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            let result = Darwin.write(descriptor, baseAddress, bytes.count)
            guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return result
        }
        guard written == line.count else { throw POSIXError(.ENOSPC) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Shared by compaction and reset: a single atomic whole-file replace.
    private func replaceJournal(with state: PhoneSyncRuntimeState) throws {
        try createParentDirectoryIfNeeded()
        var line = try Self.makeEncoder().encode(Record(seq: 0, runtimeState: state))
        line.append(UInt8(ascii: "\n"))
        try line.write(to: url, options: .atomic)
    }

    private func createParentDirectoryIfNeeded() throws {
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private struct ValidRecord {
        var record: Record
        var runtimeState: PhoneSyncRuntimeState
        var lineIndex: Int
    }

    private struct JournalRead {
        var fileExists: Bool
        var valid: [ValidRecord]
        var invalidLineCount: Int
        var nonemptyLineCount: Int

        var maximumSnapshotVersion: Int {
            valid.map(\.runtimeState.machineState.latestSnapshotVersion).max() ?? 0
        }

        var maximumTransferGeneration: Int {
            valid.map(\.runtimeState.machineState.lastTransferGeneration).max() ?? 0
        }
    }

    private func readJournal() throws -> JournalRead {
        guard fileManager.fileExists(atPath: url.path) else {
            return JournalRead(fileExists: false, valid: [], invalidLineCount: 0, nonemptyLineCount: 0)
        }
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var valid: [ValidRecord] = []
        var invalidLineCount = 0
        var nonemptyLineCount = 0
        for (index, line) in lines.enumerated() where line.isEmpty == false {
            nonemptyLineCount += 1
            guard
                let record = try? JSONDecoder().decode(Record.self, from: Data(line)),
                record.seq >= 0,
                record.hasValidChecksum,
                let runtime = try? record.fullRuntimeState.makeRuntimeState()
            else {
                invalidLineCount += 1
                continue
            }
            valid.append(ValidRecord(record: record, runtimeState: runtime, lineIndex: index))
        }
        return JournalRead(
            fileExists: true,
            valid: valid,
            invalidLineCount: invalidLineCount,
            nonemptyLineCount: nonemptyLineCount
        )
    }

    private static func replacingIdentities(
        in runtime: PhoneSyncRuntimeState,
        latestSnapshotVersion: Int,
        lastTransferGeneration: Int
    ) -> PhoneSyncRuntimeState {
        let state = runtime.machineState
        return PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(
                ackAge: state.ackAge,
                lastObservedNow: state.lastObservedNow,
                pendingStoreConfirmations: state.pendingStoreConfirmations,
                latestSnapshotVersion: latestSnapshotVersion,
                lastTransferGeneration: lastTransferGeneration,
                outstandingSnapshot: state.outstandingSnapshot
            ),
            lastDailyPushAt: runtime.lastDailyPushAt
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    struct Record: Codable {
        var seq: Int
        var fullRuntimeState: Snapshot
        var checksum: String

        init(seq: Int, runtimeState: PhoneSyncRuntimeState) throws {
            let snapshot = Snapshot(runtimeState)
            self.seq = seq
            self.fullRuntimeState = snapshot
            self.checksum = try Self.checksum(seq: seq, snapshot: snapshot)
        }

        var hasValidChecksum: Bool {
            guard let expected = try? Self.checksum(seq: seq, snapshot: fullRuntimeState) else {
                return false
            }
            return checksum == expected
        }

        private struct ChecksumPayload: Encodable {
            var seq: Int
            var fullRuntimeState: ChecksumSnapshot
        }

        /// JSON represents dictionaries keyed by UUID as alternating-value
        /// arrays, whose iteration order is not stable after a decode. The
        /// checksum therefore uses an explicitly UUID-sorted mirror rather
        /// than re-encoding `Snapshot`'s dictionaries in hash-table order.
        private struct ChecksumSnapshot: Encodable {
            struct AgeEntry: Encodable {
                var id: String
                var age: TimeInterval
            }

            struct RevisionEntry: Encodable {
                var id: String
                var revision: Int
            }

            var ackAge: [AgeEntry]
            var lastObservedNow: Date?
            var pendingRevisions: [RevisionEntry]
            var pendingAges: [AgeEntry]
            var latestSnapshotVersion: Int
            var lastTransferGeneration: Int
            var outstandingSnapshotVersion: Int?
            var outstandingSnapshotGeneration: Int?
            var lastDailyPushAt: Date?

            init(_ snapshot: Snapshot) {
                ackAge = snapshot.ackAge
                    .map { AgeEntry(id: $0.key.uuidString, age: $0.value) }
                    .sorted { $0.id < $1.id }
                lastObservedNow = snapshot.lastObservedNow
                pendingRevisions = snapshot.pendingRevisions
                    .map { RevisionEntry(id: $0.key.uuidString, revision: $0.value) }
                    .sorted { $0.id < $1.id }
                pendingAges = snapshot.pendingAges
                    .map { AgeEntry(id: $0.key.uuidString, age: $0.value) }
                    .sorted { $0.id < $1.id }
                latestSnapshotVersion = snapshot.latestSnapshotVersion
                lastTransferGeneration = snapshot.lastTransferGeneration
                outstandingSnapshotVersion = snapshot.outstandingSnapshotVersion
                outstandingSnapshotGeneration = snapshot.outstandingSnapshotGeneration
                lastDailyPushAt = snapshot.lastDailyPushAt
            }
        }

        private static func checksum(seq: Int, snapshot: Snapshot) throws -> String {
            let bytes = try FileBackedPhoneSyncStatePersisting.makeEncoder().encode(
                ChecksumPayload(seq: seq, fullRuntimeState: ChecksumSnapshot(snapshot))
            )
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            let value = String(hash, radix: 16)
            return String(repeating: "0", count: 16 - value.count) + value
        }
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
    /// field without constructing a checksum-valid hostile journal record.
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
            // m4-04 review round 2, finding 2 — see this file's header.
            guard latestSnapshotVersion <= maximumPhoneSyncIdentity else {
                throw PhoneSyncStateCorruptionError.snapshotVersionTooLarge(latestSnapshotVersion)
            }
            guard lastTransferGeneration >= 0 else {
                throw PhoneSyncStateCorruptionError.negativeTransferGeneration(lastTransferGeneration)
            }
            guard lastTransferGeneration <= maximumPhoneSyncIdentity else {
                throw PhoneSyncStateCorruptionError.transferGenerationTooLarge(lastTransferGeneration)
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

/// Read-only copy of m4-04's two-file loader. It exists solely to migrate
/// already-installed state when the new journal is absent; no save path can
/// create or update the legacy files.
private struct LegacyTwoFilePhoneSyncStateLoader {
    private let stateURL: URL
    private let highWaterURL: URL
    private let fileManager: FileManager

    private struct HighWaterRecord: Codable {
        var version: Int
        var generation: Int
    }

    private enum HighWaterOutcome {
        case absent
        case corrupt
        case value(version: Int, generation: Int)
    }

    init(stateURL: URL, highWaterURL: URL, fileManager: FileManager) {
        self.stateURL = stateURL
        self.highWaterURL = highWaterURL
        self.fileManager = fileManager
    }

    func load() throws -> PhoneSyncLoadResult? {
        let stateExists = fileManager.fileExists(atPath: stateURL.path)
        let highWater = readHighWater()

        if stateExists == false {
            switch highWater {
            case .absent:
                return nil
            case .corrupt:
                throw PhoneSyncStateUnrecoverableError()
            case let .value(version, generation):
                return PhoneSyncLoadResult(
                    runtimeState: restoringHighWater(version: version, generation: generation),
                    recoveredFromCorruption: true
                )
            }
        }

        do {
            let snapshot = try JSONDecoder().decode(
                FileBackedPhoneSyncStatePersisting.Snapshot.self,
                from: Data(contentsOf: stateURL)
            )
            var runtime = try snapshot.makeRuntimeState()
            if case let .value(version, generation) = highWater {
                runtime = mergingHighWater(into: runtime, version: version, generation: generation)
            }
            return PhoneSyncLoadResult(runtimeState: runtime, recoveredFromCorruption: false)
        } catch {
            if case let .value(version, generation) = highWater {
                return PhoneSyncLoadResult(
                    runtimeState: restoringHighWater(version: version, generation: generation),
                    recoveredFromCorruption: true
                )
            }
            throw PhoneSyncStateUnrecoverableError()
        }
    }

    private func readHighWater() -> HighWaterOutcome {
        guard fileManager.fileExists(atPath: highWaterURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: highWaterURL), data.isEmpty == false else { return .corrupt }

        var maxVersion: Int?
        var maxGeneration: Int?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let record = try? JSONDecoder().decode(HighWaterRecord.self, from: Data(line)),
                record.version >= 0, record.version <= maximumPhoneSyncIdentity,
                record.generation >= 0, record.generation <= maximumPhoneSyncIdentity
            else { continue }
            maxVersion = max(maxVersion ?? 0, record.version)
            maxGeneration = max(maxGeneration ?? 0, record.generation)
        }
        guard let version = maxVersion, let generation = maxGeneration else { return .corrupt }
        return .value(version: version, generation: generation)
    }

    private func restoringHighWater(version: Int, generation: Int) -> PhoneSyncRuntimeState {
        mergingHighWater(into: PhoneSyncRuntimeState(), version: version, generation: generation)
    }

    private func mergingHighWater(
        into runtime: PhoneSyncRuntimeState,
        version: Int,
        generation: Int
    ) -> PhoneSyncRuntimeState {
        let state = runtime.machineState
        return PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(
                ackAge: state.ackAge,
                lastObservedNow: state.lastObservedNow,
                pendingStoreConfirmations: state.pendingStoreConfirmations,
                latestSnapshotVersion: max(state.latestSnapshotVersion, version),
                lastTransferGeneration: max(state.lastTransferGeneration, generation),
                outstandingSnapshot: state.outstandingSnapshot
            ),
            lastDailyPushAt: runtime.lastDailyPushAt
        )
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
        // Round 3, §2: same write-path ceiling as the file-backed
        // conformer — tests driving a coordinator through this in-memory
        // double must exercise the same refusal production would.
        try validatePhoneSyncIdentityBounds(state)
        stored = state
    }

    public func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {
        // A single in-memory assignment is inherently all-or-nothing.
        try validatePhoneSyncIdentityBounds(state)
        stored = state
    }
}
