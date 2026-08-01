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

    /// Applies a random mutation and returns a label for diagnostics.
    /// Refusals (`SessionMutationError`) are legitimate outcomes — the
    /// point is that a refusal leaves the session untouched, which the
    /// caller checks by comparing against the pre-step snapshot.
    private func apply(
        _ step: Step,
        to session: inout ActiveSession,
        rng: inout SplitMix64,
        ids: SequentialIDs,
        clock: ManualClock
    ) -> Bool {
        let itemID = session.items.isEmpty
            ? ids.next()
            : session.items[Int.random(in: 0..<session.items.count, using: &rng)].id
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
                try SessionMutator.swapExercise(itemID: itemID, toExerciseID: ids.next(), in: &session)
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
            return true
        } catch {
            return false
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
            let applied = apply(step, to: &session, rng: &rng, ids: ids, clock: clock)
            clock.advance(TimeInterval(Int.random(in: 1...90, using: &rng)))

            let violations = session.invariantViolations()
            #expect(
                violations.isEmpty,
                "seed \(seed) step \(stepIndex) (\(step)): \(violations.joined(separator: "; "))"
            )

            if !applied {
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
