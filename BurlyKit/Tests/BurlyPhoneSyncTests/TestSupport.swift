// SPDX-License-Identifier: GPL-3.0-or-later
// Shared fixtures and test doubles for BurlyPhoneSyncTests.
import Foundation
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlyPhoneSync

enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func exercise(
        id: UUID = UUID(),
        name: String,
        muscleGroups: [MuscleGroup] = [.chest, .triceps],
        origin: ExerciseOrigin = .curated,
        needsNaming: Bool = false
    ) -> ExerciseData {
        ExerciseData(id: id, name: name, muscleGroups: muscleGroups, origin: origin, needsNaming: needsNaming)
    }

    static func routine(
        id: UUID = UUID(),
        name: String = "Push A",
        orderIndex: Int = 0,
        over exercises: [ExerciseData]
    ) -> RoutineData {
        RoutineData(
            id: id,
            name: name,
            orderIndex: orderIndex,
            items: exercises.enumerated().map { index, exercise in
                RoutineItemData(exerciseID: exercise.id, order: index, defaultSetCount: 3)
            },
            updatedAt: epoch
        )
    }

    /// A **finished** session shaped like `routine`, at revision 1, ready to
    /// go straight over the wire as a §5 `session` payload.
    static func session(
        id: UUID = UUID(),
        from routine: RoutineData,
        startedAt: Date = epoch,
        revision: Int = 1
    ) -> SessionData {
        SessionData(
            id: id,
            routineID: routine.id,
            routineName: routine.name,
            startedAt: startedAt,
            state: .logged,
            revision: revision,
            origin: .live,
            items: routine.items.map { SessionItemData(exerciseID: $0.exerciseID, order: $0.order) }
        )
    }
}

extension SessionData {
    func addingSet(_ set: SetRecordData, toItem itemID: UUID) -> SessionData {
        var copy = self
        guard let index = copy.items.firstIndex(where: { $0.id == itemID }) else { return copy }
        copy.items[index].sets.append(set)
        return copy
    }
}

/// A store clock a test drives explicitly — same shape as
/// BurlyPersistenceTests' `TestClock`, redeclared here because that one is
/// file-private to a different test target.
final class TestClock: WallClock, @unchecked Sendable {
    var now: Date

    init(_ now: Date = Fixture.epoch) {
        self.now = now
    }

    @discardableResult
    func advance(by interval: TimeInterval) -> Date {
        now = now.addingTimeInterval(interval)
        return now
    }
}

/// A fresh in-memory phone store per test.
@MainActor
func makePhoneStore(clock: any WallClock = TestClock()) throws -> SwiftDataStore {
    try SwiftDataStore(kind: .phone, at: .inMemory, clock: clock)
}

/// Settles a detached, UNTRACKED `Task` (m4-04 review round 2, findings 5
/// and 6: a catalog-retry `Task` is not held by any `QuietPeriodCoalescer`,
/// so `drainPendingDebounces()` cannot await it; `ManualTriggerScheduler
/// .settle()`'s pure `Task.yield()` loop was observed to be insufficient on
/// its own in a busy test context — with several concurrent chains recently
/// active, 50 cooperative yields did not reliably let a freshly-resumed
/// background `Task` reach and complete its own actor calls before the
/// calling test's own continuation ran again). A brief, bounded REAL sleep
/// is the standard mitigation for exactly this class of "confirm an effect
/// did NOT happen" assertion when no other completion signal is available:
/// it can only make the assertion MORE likely to catch a real straggling
/// effect, never less, so it does not introduce a wrong-direction flake —
/// the risk it trades away is a slower test, not a less trustworthy one.
func settleRealWork() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
}

// MARK: - Transport / publisher fakes

/// A `TransmitFailure`-throwing, gate-able fake transport.
///
/// - `failNextTransmitCount` / `failNextCancelCount`: fail the next N calls
///   of the respective kind (major 3's retry/surface tests).
/// - `armCancelGate()` / `releaseCancelGate()`: make
///   `cancelSnapshotTransfer` suspend until released — the deterministic
///   way to construct major 4's "one call is mid-batch when another
///   starts" scenario without a real sleep. `hasCancelGateWaiter()` lets a
///   test poll for "the gated call has actually been reached" instead of
///   guessing a delay.
actor FakeTransport: PhoneSyncTransporting {
    struct Transmission: Equatable {
        var payload: BurlySnapshotPayloadDTO
        var generation: Int
    }
    struct Cancellation: Equatable {
        var version: Int
        var generation: Int
    }
    struct TransmitFailure: Error, Equatable {}
    struct CancelFailure: Error, Equatable {}

    private(set) var transmissions: [Transmission] = []
    private(set) var cancellations: [Cancellation] = []

    private(set) var failNextTransmitCount = 0
    private(set) var failNextCancelCount = 0

    private var cancelGateArmed = false
    private var cancelGateWaiters: [CheckedContinuation<Void, Never>] = []

    func setFailNextTransmitCount(_ count: Int) {
        failNextTransmitCount = count
    }

    func setFailNextCancelCount(_ count: Int) {
        failNextCancelCount = count
    }

    func transmitSnapshot(_ payload: BurlySnapshotPayloadDTO, generation: Int) async throws {
        if failNextTransmitCount > 0 {
            failNextTransmitCount -= 1
            throw TransmitFailure()
        }
        transmissions.append(Transmission(payload: payload, generation: generation))
    }

    func cancelSnapshotTransfer(version: Int, generation: Int) async throws {
        if cancelGateArmed {
            await withCheckedContinuation { continuation in
                cancelGateWaiters.append(continuation)
            }
        }
        if failNextCancelCount > 0 {
            failNextCancelCount -= 1
            throw CancelFailure()
        }
        cancellations.append(Cancellation(version: version, generation: generation))
    }

    func armCancelGate() {
        cancelGateArmed = true
    }

    /// Releases every call currently parked on the gate and disarms it —
    /// calls made *after* this are not gated again until `armCancelGate()`
    /// is called anew.
    func releaseCancelGate() {
        cancelGateArmed = false
        let waiters = cancelGateWaiters
        cancelGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func hasCancelGateWaiter() -> Bool {
        cancelGateWaiters.isEmpty == false
    }
}

actor FakeDigestPublisher: PhoneDigestPublishing {
    private(set) var published: [BurlyDigestPayloadDTO] = []

    func publishDigest(_ payload: BurlyDigestPayloadDTO) async {
        published.append(payload)
    }
}

/// A `PhoneSyncStatePersisting` whose `save()` can be told to fail its next
/// N calls (m4-04 review round 2, finding 4): pins that a catalog-edit
/// STATE PERSISTENCE failure is surfaced/retried exactly like a transport
/// failure, rather than being swallowed by the generic `deliver(_:)`
/// helper's `try?`, which is what round-1 code still did for this one
/// specific failure path. A plain lock-protected class, not an actor:
/// `PhoneSyncStatePersisting.save` is synchronous by protocol design (see
/// that file's doc), and `PhoneSyncCoordinator` calls it from `@MainActor`
/// context — an actor here would need a fire-and-forget hop to record
/// state, reintroducing an ordering gap this double has no reason to have.
final class FailableStatePersisting: PhoneSyncStatePersisting, @unchecked Sendable {
    struct SaveFailure: Error, Equatable {}

    private let lock = NSLock()
    private var stored: PhoneSyncRuntimeState?
    private var failNextSaveCount = 0

    func setFailNextSaveCount(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        failNextSaveCount = count
    }

    func load() throws -> PhoneSyncLoadResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored.map { PhoneSyncLoadResult(runtimeState: $0, recoveredFromCorruption: false) }
    }

    func save(_ state: PhoneSyncRuntimeState) throws {
        lock.lock()
        if failNextSaveCount > 0 {
            failNextSaveCount -= 1
            lock.unlock()
            throw SaveFailure()
        }
        stored = state
        lock.unlock()
    }
}
