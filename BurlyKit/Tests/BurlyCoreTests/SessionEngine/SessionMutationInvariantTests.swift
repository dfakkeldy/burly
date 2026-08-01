// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #1, property-style: random routines, random mutation
// sequences, and after *every* step the two things §2 actually promises —
// the ordering invariants hold, and no logged set was harmed.
//
// The example-based suites above pin the behaviour of each operation. This
// one pins the behaviour of arbitrary *combinations*, which is where an
// ordering bug would really live: a reorder after an insert after a skip.
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 mutation invariants (property-style)")
struct SessionMutationInvariantTests {

    /// One randomly chosen mutation, applied to a session.
    private enum Step: CaseIterable {
        case addSet, removeEmptySet, logSet, skip, swap, addExercise, addPlaceholder, moveUp, moveDown
    }

    /// What one generated step did, against what the generator already knew
    /// it should do.
    private struct StepOutcome {
        /// Whether the generator, looking at the session *before* the call,
        /// could tell the operation was valid.
        var shouldSucceed: Bool
        var didSucceed: Bool
        var error: (any Error)?
    }

    /// Applies a random mutation, having first worked out whether it can
    /// legitimately be refused.
    ///
    /// The generator knows the session it is mutating, so for most steps it
    /// knows the answer in advance: adding a set to an item that exists
    /// cannot fail, and moving an item that is not at the edge cannot fail.
    /// Treating every `SessionMutationError` as an acceptable outcome would
    /// let this whole suite pass over an engine that refused *everything* —
    /// the invariants hold beautifully on a session nothing can touch. So
    /// each step is predicted, and the prediction is asserted.
    private func apply(
        _ step: Step,
        to session: inout ActiveSession,
        rng: inout SplitMix64,
        ids: SequentialIDs,
        clock: ManualClock
    ) -> StepOutcome {
        let itemID = session.items.isEmpty
            ? ids.next()
            : session.items[Int.random(in: 0..<session.items.count, using: &rng)].id
        let index = session.index(ofItem: itemID)
        let planned = session.plannedSetCount(itemID)
        let logged = session.loggedSetCount(itemID)

        // Predicted before the call, from state the generator can see. No
        // RNG is drawn here, so the generated sequence is unchanged.
        let shouldSucceed: Bool
        switch step {
        case .addSet, .logSet, .skip, .swap:
            // The session is always `.active` in this suite (no step
            // finishes it), so existence of the item is the only question.
            // Reps are drawn from 1...15, so `logSet` is never invalid.
            shouldSucceed = index != nil
        case .removeEmptySet:
            shouldSucceed = index != nil && planned > logged && planned > 1
        case .addExercise, .addPlaceholder:
            // Always appended or inserted at an in-range index below.
            shouldSucceed = true
        case .moveUp:
            shouldSucceed = (index ?? 0) > 0
        case .moveDown:
            shouldSucceed = index.map { $0 < session.items.count - 1 } ?? false
        }

        do {
            switch step {
            case .addSet:
                try SessionMutator.addSet(toItem: itemID, in: &session)
            case .removeEmptySet:
                try SessionMutator.removeEmptySet(fromItem: itemID, in: &session)
            case .logSet:
                try SessionMutator.logSet(
                    itemID: itemID,
                    weight: Weight(kg: Double(Int.random(in: 0...200, using: &rng))),
                    reps: Int.random(in: 1...15, using: &rng),
                    isWarmup: Bool.random(using: &rng),
                    in: &session,
                    clock: clock,
                    makeID: ids.make
                )
            case .skip:
                try SessionMutator.skipExercise(itemID: itemID, in: &session)
            case .swap:
                try SessionMutator.swapExercise(
                    itemID: itemID, toExerciseID: ids.next(), in: &session, makeID: ids.make
                )
            case .addExercise:
                try SessionMutator.addExercise(
                    exerciseID: ids.next(),
                    plannedSetCount: Int.random(in: 0...5, using: &rng),
                    at: session.items.isEmpty ? 0 : Int.random(in: 0...session.items.count, using: &rng),
                    in: &session,
                    makeID: ids.make
                )
            case .addPlaceholder:
                try SessionMutator.addPlaceholderExercise(in: &session, makeID: ids.make)
            case .moveUp:
                try SessionMutator.moveItemUp(itemID: itemID, in: &session)
            case .moveDown:
                try SessionMutator.moveItemDown(itemID: itemID, in: &session)
            }
            return StepOutcome(shouldSucceed: shouldSucceed, didSucceed: true, error: nil)
        } catch {
            return StepOutcome(shouldSucceed: shouldSucceed, didSucceed: false, error: error)
        }
    }

    @Test("Invariants I1–I5 survive 200 random mutation sequences", arguments: 1...200)
    func invariantsSurviveRandomSequences(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed &* 0x2545_F491_4F6C_DD1D)
        let ids = SequentialIDs()
        let clock = ManualClock()
        var session = SessionBuilder.session(
            from: Fixture.randomRoutine(using: &rng, ids: ids),
            clock: clock,
            makeID: ids.make
        )
        #expect(session.invariantViolations().isEmpty)

        for stepIndex in 0..<30 {
            let step = Step.allCases[Int.random(in: 0..<Step.allCases.count, using: &rng)]
            let before = session
            let outcome = apply(step, to: &session, rng: &rng, ids: ids, clock: clock)
            clock.advance(TimeInterval(Int.random(in: 1...90, using: &rng)))

            let violations = session.invariantViolations()
            #expect(
                violations.isEmpty,
                "seed \(seed) step \(stepIndex) (\(step)): \(violations.joined(separator: "; "))"
            )

            // An operation the generator knows is valid must be performed,
            // and one it knows is invalid must be refused. Only genuine
            // refusals count as refusals.
            #expect(
                outcome.didSucceed == outcome.shouldSucceed,
                """
                seed \(seed) step \(stepIndex): \(step) should have \
                \(outcome.shouldSucceed ? "succeeded" : "been refused") but was \
                \(outcome.didSucceed ? "performed" : "refused with \(String(describing: outcome.error))")
                """
            )

            if !outcome.didSucceed {
                // A refused mutation must be a no-op, not a partial edit.
                #expect(session == before, "seed \(seed) step \(stepIndex): refused \(step) mutated the session")
                continue
            }

            // I5: no logged set is ever edited or dropped. Logging adds one
            // and leaves the rest alone; everything else preserves the set
            // multiset exactly.
            let beforeSets = Set(before.allSets)
            let afterSets = Set(session.allSets)
            if step == .logSet {
                #expect(beforeSets.isSubset(of: afterSets))
                #expect(afterSets.count == beforeSets.count + 1)
            } else {
                #expect(afterSets == beforeSets, "seed \(seed) step \(stepIndex): \(step) altered logged sets")
            }
        }
    }

    @Test("A random mutation sequence never loses an item, only adds", arguments: 1...50)
    func itemsAreNeverLost(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed &* 0x9E37_79B9_7F4A_7C15)
        let ids = SequentialIDs()
        let clock = ManualClock()
        var session = SessionBuilder.session(
            from: Fixture.randomRoutine(using: &rng, ids: ids),
            clock: clock,
            makeID: ids.make
        )
        let originalItemIDs = Set(session.items.map(\.id))

        for _ in 0..<25 {
            let step = Step.allCases[Int.random(in: 0..<Step.allCases.count, using: &rng)]
            _ = apply(step, to: &session, rng: &rng, ids: ids, clock: clock)
        }

        // §2 has no "remove exercise" — skip is the non-destructive
        // substitute — so every item that entered the session is still in it.
        #expect(originalItemIDs.isSubset(of: Set(session.items.map(\.id))))
        #expect(session.invariantViolations().isEmpty)
    }

    @Test("Every mutated session still round-trips through JSON", arguments: 1...25)
    func mutatedSessionsRoundTrip(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed &* 0xBF58_476D_1CE4_E5B9)
        let ids = SequentialIDs()
        let clock = ManualClock()
        var session = SessionBuilder.session(
            from: Fixture.randomRoutine(using: &rng, ids: ids),
            clock: clock,
            makeID: ids.make
        )
        for _ in 0..<15 {
            let step = Step.allCases[Int.random(in: 0..<Step.allCases.count, using: &rng)]
            _ = apply(step, to: &session, rng: &rng, ids: ids, clock: clock)
        }

        #expect(try roundTripJSON(session) == session)
    }
}
