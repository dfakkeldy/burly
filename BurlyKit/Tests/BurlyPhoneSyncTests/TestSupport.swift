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
