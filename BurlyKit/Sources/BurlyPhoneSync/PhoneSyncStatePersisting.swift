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
//
// ## Round 2, finding 2: an upper bound, not just a lower one
//
// The round-1 validator above only ever checked `>= 0` — a syntactically
// valid line/file carrying `Int.max` for `latestSnapshotVersion` or
// `lastTransferGeneration` sailed through both `Snapshot.makeRuntimeState()`
// and `HighWaterMarkLog.currentHighWater()`'s per-line check, and then
// trapped on the very next `PhoneSyncMachine` `+= 1` (`.catalogChanged`'s
// version bump, `replaceOutstandingTransfer`'s generation bump) — the exact
// same class of hole `SessionData.maximumRevision` (m4-04 review round 1,
// major 7) closed for wire/store revisions, just left open here.
// `maximumPhoneSyncIdentity` below is that same "generous ceiling far below
// `Int.max`" pattern, applied at BOTH deserialization boundaries this file
// owns: the primary state's fields, and the high-water log's per-line
// records.
//
// ## Round 2, finding 1: "both unreadable" must not degrade to zero
//
// Round 1's fix restores `latestSnapshotVersion`/`lastTransferGeneration`
// from the high-water log whenever the *primary* is missing, unreadable, or
// semantically invalid. It missed the case where the high-water log
// *itself* cannot be trusted either — `HighWaterMarkLog`'s old
// `currentHighWater()` returned the tuple `(0, 0)` both when the log file
// had never been written (genuine first launch) AND when it existed but
// every line failed to parse (a real prior install whose recovery record is
// now gone) — two very different situations, silently conflated into the
// same "safe to start from zero" answer. The fix distinguishes them
// explicitly:
//
// - **Both files genuinely absent** (never written) — a true first launch.
//   Zero is the correct, uncontroversial answer; `load()` returns `nil`.
// - **Either file is *present* but unreadable/corrupt** — this phone has
//   synced before, and least one of the two records of that fact cannot be
//   trusted. If the OTHER one still holds a usable value, round 1's
//   recovery already handles it. But if *neither* can produce a usable
//   value, there is no true high-water left to recover, and reconstructing
//   a state at zero here would reopen the exact "generation reuse aliases a
//   live transfer" / "regressed version wedges the watch" hazard round 1
//   closed for the single-file case. `load()` throws
//   `PhoneSyncStateUnrecoverableError` instead — a typed, catchable signal
//   `PhoneSyncCoordinator` surfaces as `syncStateUnrecoverable`, whose
//   correct operator response is re-pairing/rebuilding the sync
//   relationship from scratch, a deliberate and visible reset, not a
//   runtime that quietly reused or lost identities without telling anyone.
import Foundation
import BurlySync
import BurlySyncMachine

/// m4-04 review round 2, finding 2 + round 3, §2 — see this file's header.
/// The single **inclusive** ceiling on `latestSnapshotVersion` and
/// `lastTransferGeneration`, enforced identically at every boundary this
/// file owns:
///
/// - **Read**: `Snapshot.makeRuntimeState()` (the primary state's fields)
///   and `HighWaterMarkLog.read()`'s per-line validation both reject a
///   value above it (round 2, finding 2).
/// - **Write** (round 3, §2): `save(_:)` — in every conformer — throws
///   `PhoneSyncIdentityOverflowError` *before* writing anything (including
///   the high-water append) when the state to persist carries a value
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
/// the primary file nor the high-water log ever holds an out-of-range
/// value, and `PhoneSyncCoordinator`'s persist-before-execute ordering
/// means the transport never sees one either.
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

/// Thrown by `load()` (m4-04 review round 2, finding 1 — see this file's
/// header): neither the primary state file nor the high-water-mark log
/// could produce a trustworthy identity. Deliberately distinct from
/// `PhoneSyncStateCorruptionError` (which names one bad field inside an
/// otherwise-readable source) — this means the *combination* of both
/// sources this type relies on gives no usable answer at all, not that one
/// of them named a specific violation.
public struct PhoneSyncStateUnrecoverableError: Error, Equatable {
    public init() {}
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
    ///
    /// Round 3, §2: conformances must **refuse** (throw
    /// `PhoneSyncIdentityOverflowError`, via
    /// `validatePhoneSyncIdentityBounds(_:)`) a state whose
    /// `latestSnapshotVersion` or `lastTransferGeneration` falls outside
    /// `0...maximumPhoneSyncIdentity`, before writing anything — the write
    /// path is where the ceiling actually binds, since the coordinator
    /// persists before it transmits.
    func save(_ state: PhoneSyncRuntimeState) throws

    /// Round 4, §2 — the domain-reset write, distinct from `save(_:)` on
    /// purpose. `save` may keep durable redundancy in whatever incremental
    /// form it likes (the file-backed conformer's append-only high-water
    /// log), because ordinary saves only ever move identities UPWARD — a
    /// partial write there is at worst an orphaned record naming an
    /// identity at-or-above everything transmitted, which recovery treats
    /// safely. A reset writes a **lower** identity (a fresh zero domain),
    /// where a partial write is precisely the hazard: an orphaned zero
    /// record from a reset that then failed could be "recovered" on the
    /// next launch, silently clearing quiescence and reusing generations
    /// from the lost domain.
    ///
    /// Contract: **all durable records commit, or none do.** On any thrown
    /// error, the durable state must be indistinguishable from "this call
    /// never happened" — in particular, no partial fresh-domain record may
    /// ever become recoverable by `load()`. Conformances must also
    /// validate the state via `validatePhoneSyncIdentityBounds(_:)` before
    /// writing, like `save`.
    func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws
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
        let primaryExists = fileManager.fileExists(atPath: url.path)
        let highWaterOutcome = highWaterLog.read()

        if primaryExists == false {
            switch highWaterOutcome {
            case .absent:
                // m4-04 review round 2, finding 1: BOTH files are
                // genuinely absent — the one combination where "nothing
                // saved, start at zero" is actually correct, not a guess.
                return nil
            case .corrupt:
                // The high-water log EXISTS (this phone has synced
                // before) but nothing in it could be trusted, and the
                // primary is simply gone. There is no true high-water
                // left to recover; resetting to zero here is exactly the
                // fail-open reset round 1 closed for "one file corrupt" —
                // it must not reopen for "both."
                throw PhoneSyncStateUnrecoverableError()
            case let .value(version, generation):
                // The primary was lost but the high-water log survived
                // intact — round 1's fix, unchanged.
                return PhoneSyncLoadResult(
                    runtimeState: PhoneSyncRuntimeState(
                        machineState: Self.stateRestoringHighWater((version, generation))
                    ),
                    recoveredFromCorruption: true
                )
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            var runtime = try snapshot.makeRuntimeState()
            if case let .value(version, generation) = highWaterOutcome {
                // Defensive max-merge even on a clean decode: `save()`
                // always writes the high-water log before the primary
                // file (see this file's header), so the primary should
                // already be at or above the log — this only ever matters
                // if something wrote the primary file through a path
                // other than `save()`. A `.corrupt`/`.absent` log
                // alongside a primary that decoded fine is NOT this
                // finding's scenario — the primary is trustworthy on its
                // own here, so there is nothing to merge.
                runtime.machineState = Self.mergingHighWater(into: runtime.machineState, (version, generation))
            }
            return PhoneSyncLoadResult(runtimeState: runtime, recoveredFromCorruption: false)
        } catch {
            // Primary EXISTS but is unreadable (I/O) or semantically
            // invalid (`PhoneSyncStateCorruptionError` from
            // `makeRuntimeState`).
            switch highWaterOutcome {
            case let .value(version, generation):
                // A **surfaced** recovery: every self-healing fact resets
                // to empty, but the monotonic identities are restored
                // from the high-water log, never reused from zero.
                return PhoneSyncLoadResult(
                    runtimeState: PhoneSyncRuntimeState(
                        machineState: Self.stateRestoringHighWater((version, generation))
                    ),
                    recoveredFromCorruption: true
                )
            case .absent, .corrupt:
                // m4-04 review round 2, finding 1: the primary is present
                // but untrustworthy AND the high-water log gives nothing
                // to fall back on either — the exact "both unreadable"
                // scenario that used to silently degrade to zero.
                // Surfaced, not swallowed.
                throw PhoneSyncStateUnrecoverableError()
            }
        }
    }

    public func save(_ state: PhoneSyncRuntimeState) throws {
        // Round 3, §2: the write-path ceiling, checked before ANY byte is
        // written — an out-of-range identity must not reach even the
        // high-water log (where `read()` would skip it, but a value that
        // should never exist should also never be written).
        try validatePhoneSyncIdentityBounds(state)

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

    /// Round 4, §2 — see the protocol requirement's doc. Write order is the
    /// REVERSE of `save(_:)`, deliberately:
    ///
    /// - **Primary first, atomically.** Until that rename lands, nothing on
    ///   disk has changed at all; if it throws, the old (corrupt) files
    ///   remain exactly as they were — durably indistinguishable from
    ///   "reset never happened", which keeps the next launch unrecoverable
    ///   and quiescent rather than operational at a zero that was never
    ///   committed. (`save`'s log-append-first order exists so a crash
    ///   between its two writes leaves the log naming the *higher*
    ///   identity about to be used — the safe direction for ordinary,
    ///   upward saves. For a reset, that same order is exactly the
    ///   laundering hazard: an orphaned LOWER record that a failed reset
    ///   leaves behind for recovery to trust.)
    /// - **Then the high-water log, atomically REPLACED, not appended.**
    ///   The old log is the record of the old identity domain (or of its
    ///   corruption); the fresh domain starts its own log with a single
    ///   record. A crash between the two writes leaves a fully-valid
    ///   primary beside the old unreadable log — `load()` treats a
    ///   decodable primary as authoritative when the log yields nothing
    ///   usable, so the reset is *committed* in that window, never
    ///   half-recovered. (From the only state the coordinator calls this
    ///   in — unrecoverable — the old log by definition holds zero valid
    ///   records, so the defensive max-merge in `load()` has nothing to
    ///   resurrect either.)
    public func replaceWithFreshIdentityDomain(_ state: PhoneSyncRuntimeState) throws {
        try validatePhoneSyncIdentityBounds(state)

        let data = try JSONEncoder().encode(Snapshot(state))
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)

        try highWaterLog.replace(
            version: state.machineState.latestSnapshotVersion,
            generation: state.machineState.lastTransferGeneration
        )
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

/// `HighWaterMarkLog.read()`'s result (m4-04 review round 2, finding 1):
/// distinguishes "this log was never written" from "this log exists but
/// nothing in it can be trusted" — two situations round 1's `(0, 0)`-tuple
/// return conflated into the same answer, which is exactly the gap that let
/// "primary absent, log corrupt" (a real prior install, not a first launch)
/// silently degrade to zero.
enum HighWaterReadOutcome: Equatable {
    /// The log file does not exist on disk at all.
    case absent
    /// The log file exists, but no line in it yielded a trustworthy record
    /// (parse failure, a negative field, or a field above
    /// `maximumPhoneSyncIdentity` — round 2, finding 2).
    case corrupt
    /// At least one line parsed to a valid, in-range record; this is the
    /// max across every such line.
    case value(version: Int, generation: Int)
}

/// The append-only high-water-mark log (blocker 1): one line per `save()`
/// call, `{"version":N,"generation":M}\n`, appended via `FileHandle` rather
/// than read-modify-rewrite — a crash mid-append can only corrupt the last
/// line, never an earlier one, which is the whole point (a single
/// atomically-overwritten record has no earlier line to fall back on if
/// *its* one write is the one that's damaged).
///
/// `read()` tolerates the log's own corruption: a line that fails to parse,
/// or parses to a field that is negative or above `maximumPhoneSyncIdentity`
/// (round 2, finding 2), is skipped rather than aborting the read, and the
/// result is the max of every field across every line that *did* parse. If
/// every line is corrupt (a double failure far rarer than either file
/// corrupting alone), this reports `.corrupt`, not a silent `(0, 0)` — see
/// `HighWaterReadOutcome`'s doc and this file's header for why that
/// distinction is now load-bearing.
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

    func read() -> HighWaterReadOutcome {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return .corrupt }

        var maxVersion: Int?
        var maxGeneration: Int?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let record = try? JSONDecoder().decode(Record.self, from: Data(line)),
                record.version >= 0, record.version <= maximumPhoneSyncIdentity,
                record.generation >= 0, record.generation <= maximumPhoneSyncIdentity
            else { continue }
            maxVersion = max(maxVersion ?? 0, record.version)
            maxGeneration = max(maxGeneration ?? 0, record.generation)
        }
        guard let version = maxVersion, let generation = maxGeneration else { return .corrupt }
        return .value(version: version, generation: generation)
    }

    /// A plain-tuple convenience for `append`'s own compaction step, which
    /// only ever needs "what's the max to fold in" for a write already in
    /// progress — never a signal to surface to a caller — so
    /// `.absent`/`.corrupt` collapsing to `(0, 0)` here costs nothing
    /// `read()`'s callers care about (see `HighWaterReadOutcome`'s doc for
    /// why that collapse is exactly the thing `load()` itself must NOT do).
    private func currentHighWater() -> (version: Int, generation: Int) {
        if case let .value(version, generation) = read() {
            return (version, generation)
        }
        return (0, 0)
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

    /// Round 4, §2: atomically REPLACES the entire log with a single
    /// record — the domain-reset write. Append-only is the right shape for
    /// ordinary saves (identities only move upward, so a torn append is
    /// harmlessly high), but a reset writes a LOWER identity, where any
    /// partial record is the laundering hazard §2 names — so the whole
    /// file changes in one rename or not at all, using the same atomic
    /// write the compaction path already relies on.
    func replace(version: Int, generation: Int) throws {
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var line = try JSONEncoder().encode(Record(version: version, generation: generation))
        line.append(UInt8(ascii: "\n"))
        try line.write(to: url, options: .atomic)
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
        // A single in-memory assignment is inherently all-or-nothing —
        // the two-file atomicity concern (round 4, §2) has no analogue
        // here beyond the shared bound check.
        try validatePhoneSyncIdentityBounds(state)
        stored = state
    }
}
