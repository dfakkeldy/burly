// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

/// Compile-level Sendable check: this file only compiles if every type
/// passed to `requireSendable` conforms to `Sendable`. There is no runtime
/// assertion possible for a marker protocol — a build failure here *is*
/// the test failing.
private func requireSendable<T: Sendable>(_ value: T) -> T { value }

@Suite("Sendable conformance (compile-level)")
struct SendableConformanceTests {
    @Test("every BurlyCore domain type and enum is Sendable")
    func allDomainTypesAreSendable() {
        _ = requireSendable(ExerciseData(name: "Squat", muscleGroups: [.quads, .glutes], origin: .curated))
        _ = requireSendable(RoutineData(name: "Leg Day", orderIndex: 0, updatedAt: Date()))
        _ = requireSendable(RoutineItemData(exerciseID: nil, order: 0))
        _ = requireSendable(SessionData(startedAt: Date(), origin: .live))
        _ = requireSendable(SessionItemData(exerciseID: nil, order: 0))
        _ = requireSendable(SetRecordData(order: 0, weight: .bodyweight, reps: 1, completedAt: Date()))
        _ = requireSendable(SetSnapshot(weight: .bodyweight, reps: 1))
        _ = requireSendable(Weight.bodyweight)
        _ = requireSendable(MuscleGroup.chest)
        _ = requireSendable(ExerciseOrigin.curated)
        _ = requireSendable(SessionState.active)
        _ = requireSendable(SessionOrigin.live)
        #expect(Bool(true))
    }

    @Test("domain values can cross an actor boundary without a compiler error")
    func crossesActorBoundary() async {
        let session = SessionData(startedAt: Date(), origin: .live)
        let echoed = await SendableEchoActor().echo(session)
        #expect(echoed == session)
    }
}

private actor SendableEchoActor {
    func echo<T: Sendable>(_ value: T) -> T { value }
}
