// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 input model: "Prefill: weight/reps prefill from last session's
// same set index; fallback: previous set this session; fallback: empty",
// and §2 acceptance #5's "absent digest … no stale data".
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 Prefill resolution")
struct SetPrefillResolverTests {
    private let exerciseID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func loggedSet(kg: Double, reps: Int, order: Int) -> SetRecordData {
        SetRecordData(
            order: order,
            weight: Weight(kg: kg),
            reps: reps,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("Rung 1: last session's numbers for the same set index win")
    func lastPerformanceWins() {
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60, 65, 70], reps: [10, 8, 6])

        let prefill = SetPrefillResolver.prefill(
            exerciseID: exerciseID,
            setIndex: 1,
            loggedSets: [loggedSet(kg: 100, reps: 3, order: 0)],
            lastPerformance: digest
        )

        #expect(prefill.source == .lastPerformance)
        #expect(prefill.weight == Weight(kg: 65))
        #expect(prefill.reps == 8)
    }

    @Test("Rung 2: past the end of the digest, the previous set this session is used")
    func fallsBackToPreviousSetThisSession() {
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60], reps: [10])

        let prefill = SetPrefillResolver.prefill(
            exerciseID: exerciseID,
            setIndex: 1,
            loggedSets: [loggedSet(kg: 100, reps: 3, order: 0)],
            lastPerformance: digest
        )

        #expect(prefill.source == .previousSetThisSession)
        #expect(prefill.weight == Weight(kg: 100))
        #expect(prefill.reps == 3)
    }

    @Test("Rung 2 also covers a missing digest entirely")
    func fallsBackWithNoDigest() {
        let prefill = SetPrefillResolver.prefill(
            exerciseID: exerciseID,
            setIndex: 2,
            loggedSets: [loggedSet(kg: 80, reps: 5, order: 0), loggedSet(kg: 82.5, reps: 4, order: 1)],
            lastPerformance: nil
        )

        #expect(prefill.source == .previousSetThisSession)
        #expect(prefill.weight == Weight(kg: 82.5))
        #expect(prefill.reps == 4)
    }

    @Test("Rung 3: first set of an exercise never performed before is empty, not a guess")
    func emptyWhenNothingToGoOn() {
        let prefill = SetPrefillResolver.prefill(
            exerciseID: exerciseID,
            setIndex: 0,
            loggedSets: [],
            lastPerformance: nil
        )

        #expect(prefill == .empty)
        #expect(prefill.weight == nil)
        #expect(prefill.reps == nil)
        #expect(prefill.isEmpty)
    }

    @Test("A digest for a different exercise is ignored (rung 1, in isolation)")
    func digestForAnotherExerciseIsIgnored() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let digest = Fixture.digest(exerciseID: other, weightsKg: [60, 65], reps: [10, 8])

        let prefill = SetPrefillResolver.prefill(
            exerciseID: exerciseID,
            setIndex: 0,
            loggedSets: [],
            lastPerformance: digest
        )

        #expect(prefill == .empty)
        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: 0, lastPerformance: digest) == nil)
    }

    @Test("The real dangerous sequence: log heavy for one exercise, swap, and nothing leaks into the next")
    func swappingMidExerciseCannotLeakThePreviousExercisesWeight() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [3], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemA = engine.session.items[0].id
        let exerciseA = engine.session.item(itemA)!.exerciseID!

        // A heavy working set of exercise A. Rung 2 now offers it back for
        // A's next set, which is correct — for A.
        try engine.logSet(itemID: itemA, weight: Weight(kg: 100), reps: 5, makeID: ids.make)
        #expect(engine.prefill(forItem: itemA, lastPerformance: nil).weight == Weight(kg: 100))

        // Mid-exercise swap to B: the bar is being unloaded, and 100 kg is
        // emphatically not the number to seed the new exercise with.
        let itemB = try engine.swapExercise(
            itemID: itemA, toExerciseID: ids.next(), makeID: ids.make
        )

        #expect(engine.prefill(forItem: itemB, lastPerformance: nil) == .empty)

        // Not even with A's digest in hand — it is keyed to A's exercise.
        let digestForA = Fixture.digest(exerciseID: exerciseA, weightsKg: [100], reps: [5])
        #expect(engine.prefill(forItem: itemB, lastPerformance: digestForA) == .empty)

        // And A's set is still A's set, under A's exercise.
        #expect(engine.session.item(itemA)?.exerciseID == exerciseA)
        #expect(engine.session.item(itemA)?.sets.map(\.weightKg) == [100])
        #expect(engine.session.item(itemB)?.sets.isEmpty == true)
        #expect(engine.session.item(itemB)?.exerciseID != exerciseA)
    }

    @Test("An item with no exercise (unnamed placeholder before assignment) prefills empty")
    func noExerciseIDPrefillsEmpty() {
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60], reps: [10])

        let prefill = SetPrefillResolver.prefill(
            exerciseID: nil,
            setIndex: 0,
            loggedSets: [],
            lastPerformance: digest
        )

        #expect(prefill == .empty)
    }

    @Test("The ghost row shows last session only, and nothing past the digest's end")
    func ghostRowShowsLastSessionOnly() {
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60, 65], reps: [10, 8])

        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: 0, lastPerformance: digest)?.reps == 10)
        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: 1, lastPerformance: digest)?.weight == Weight(kg: 65))
        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: 2, lastPerformance: digest) == nil)
        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: 0, lastPerformance: nil) == nil)
    }

    @Test("A negative set index is not a crash and not a guess")
    func negativeIndexIsEmpty() {
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60], reps: [10])

        #expect(SetPrefillResolver.ghost(exerciseID: exerciseID, setIndex: -1, lastPerformance: digest) == nil)
        #expect(
            SetPrefillResolver.prefill(
                exerciseID: exerciseID, setIndex: -1, loggedSets: [], lastPerformance: digest
            ) == .empty
        )
    }
}
