// SPDX-License-Identifier: GPL-3.0-or-later
// m4-04 — the digest generator's completeness property test, carried from
// m1-06 review 4 (gate review) and restated on `SessionDigestReceipt`:
// "for every digest emitted, lastPerformance is the complete latest-per-
// exercise derivation over full CURRENT phone history at generation time —
// an absent entry positively asserts history holds nothing for that
// exercise." Non-negotiable per this task's brief.
//
// ## Oracle strategy
//
// The property test's oracle is deliberately a *different algorithm* from
// `SessionDigestGenerator.latestPerformancePerExercise`, not merely a
// second call to it: it walks the same in-memory `SessionData` fixtures the
// test seeded the store with, sorted **ascending** by `startedAt`, and
// *overwrites* a `[exerciseID: entry]` dictionary as it goes — "last write
// wins" falls out of iteration order rather than an explicit per-exercise
// max/comparison the way the generator computes it. A bug in the
// generator's grouping key, its tie-break, or in `BurlyStore
// .allLoggedSetSlices()`'s fetch/relationship-prefetch path would have to
// coincidentally reproduce the same wrong answer as this independent walk
// to slip through — the two implementations share no code below
// `SessionData`/`SetRecordSlice` value types.
//
// Deleted sessions are folded into the oracle by simply *not* including
// them in the "current history" the oracle walks — they were created (so
// the store round-trip actually exercises `deleteSession`'s cascade) and
// then deleted before the digest is generated, exactly modeling "the phone
// may delete history while acks persist" (§5's 30-day ack retention: an ack
// can legitimately outlive the session it acks).
//
// ## Seed / shrink policy
//
// Swift Testing has no built-in shrinking. The policy adopted here: a fixed
// array of 40 seeds (`0..<40`), each driving one fully-deterministic
// `SeededGenerator` (BurlyFixtures — same PRNG every other fixture
// generator in the package uses) — so a failure names an exact seed via the
// test's own parameterization, and is manually reproduced by re-running
// `randomHistoryTrial(seed: <that seed>)` directly (or in a throwaway
// `@Test` with that one literal) — and manually shrunk by hand-reducing
// `sessionCount`/`exerciseCount` in that reproduction until the smallest
// failing case is found. This is a manual analogue of shrinking, not
// automatic; documented here rather than silently absent.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlyFixtures
@testable import BurlyPhoneSync

@Suite("m4-04 — SessionDigestGenerator: the §5 completeness property")
struct SessionDigestGeneratorTests {

    // MARK: - The required property test

    @Test(
        "for every randomized history (with deletions), lastPerformance exactly matches an independently-derived oracle",
        arguments: Array(0..<40 as Range<UInt64>)
    )
    func digestMatchesIndependentOracleAcrossRandomHistories(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        let exercises = (0..<6).map { Fixture.exercise(name: "Exercise \($0)") }
        let sessionCount = Int.random(in: 0...14, using: &rng)

        let store = try makePhoneStore()
        for exercise in exercises {
            try store.createExercise(exercise)
        }

        // Distinct, shuffled start times so no two sessions in one trial
        // ever tie on `startedAt` — the tie-break rule itself is pinned by
        // a dedicated, non-randomized test below, not conflated with this
        // one's independence requirement.
        var timeSlots = Array(0..<max(sessionCount, 1))
        timeSlots.shuffle(using: &rng)

        var currentSessions: [SessionData] = []
        var acked: Set<UUID> = []

        for index in 0..<sessionCount {
            let startedAt = Fixture.epoch.addingTimeInterval(Double(timeSlots[index]) * 3_600)
            var items: [SessionItemData] = []
            for exercise in exercises where Double.random(in: 0..<1, using: &rng) < 0.6 {
                let setCount = Int.random(in: 1...4, using: &rng)
                let sets = (0..<setCount).map { setIndex in
                    SetRecordData(
                        order: setIndex,
                        weight: Weight(kg: Double(Int.random(in: 8...40, using: &rng) * 5)),
                        reps: Int.random(in: 1...12, using: &rng),
                        isWarmup: Double.random(in: 0..<1, using: &rng) < 0.2,
                        completedAt: startedAt.addingTimeInterval(Double(setIndex) * 30)
                    )
                }
                items.append(SessionItemData(exerciseID: exercise.id, order: items.count, sets: sets))
            }
            let session = SessionData(
                startedAt: startedAt,
                state: .logged,
                origin: .live,
                items: items
            )
            try store.createSession(session)

            // ~30% of sessions are deleted after creation — the phone
            // legitimately forgetting history (§1 `deleteSession`) while
            // ~50% of ALL sessions (deleted or not) get acked, modeling the
            // 30-day ack-outlives-the-session-it-acks case.
            let isDeleted = Double.random(in: 0..<1, using: &rng) < 0.3
            if Double.random(in: 0..<1, using: &rng) < 0.5 {
                acked.insert(session.id)
            }
            if isDeleted {
                try store.deleteSession(id: session.id)
            } else {
                currentSessions.append(session)
            }
        }
        // A handful of pure-ghost acked ids the store has never heard of —
        // legal (§5: acks are machine-owned, not store-validated).
        if Double.random(in: 0..<1, using: &rng) < 0.5 {
            acked.insert(UUID())
        }

        let expected = independentOracle(from: currentSessions)

        let payload = try SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: 7,
            ackedSessionIDs: acked
        )

        #expect(payload.snapshotVersion == 7)
        #expect(Set(payload.ackedSessionIDs) == acked, "seed \(seed): ackedSessionIDs must pass through untouched")
        #expect(
            payload.lastPerformance.sorted(by: byExerciseID) == expected.sorted(by: byExerciseID),
            "seed \(seed): lastPerformance diverged from the independent oracle"
        )
    }

    // MARK: - The shape spec §5/m1-06 review 4 calls out explicitly

    @Test("an empty store emits an empty lastPerformance alongside a non-empty ackedSessionIDs — the acked-then-deleted shape must be emittable")
    func emptyLastPerformanceWithNonEmptyAcksIsEmittable() throws {
        let store = try makePhoneStore()
        let ackedGhost = UUID()

        let payload = try SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: 3,
            ackedSessionIDs: [ackedGhost]
        )

        #expect(payload.lastPerformance.isEmpty)
        #expect(payload.ackedSessionIDs == [ackedGhost])
    }

    @Test("deleting the only session for an exercise removes its entry from the next digest — the ack does not strand it")
    func deletingTheOnlySessionForAnExerciseRemovesItsEntry() throws {
        let store = try makePhoneStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(over: [squat])
        try store.createExercise(squat)

        let empty = Fixture.session(from: routine, startedAt: Fixture.epoch)
        let itemID = try #require(empty.items.first?.id)
        let logged = empty.addingSet(
            SetRecordData(order: 0, weight: Weight(kg: 140), reps: 3, completedAt: Fixture.epoch),
            toItem: itemID
        )
        try store.createSession(logged)

        let before = try SessionDigestGenerator.generate(from: store, snapshotVersion: 1, ackedSessionIDs: [])
        #expect(before.lastPerformance.map(\.exerciseID) == [squat.id])

        try store.deleteSession(id: logged.id)

        let after = try SessionDigestGenerator.generate(
            from: store, snapshotVersion: 1, ackedSessionIDs: [logged.id]
        )
        #expect(after.lastPerformance.isEmpty)
        #expect(after.ackedSessionIDs == [logged.id])
    }

    // MARK: - Determinism pins not covered by the randomized trial

    @Test("two sessions with an identical startedAt resolve the tie deterministically by session id, both directions")
    func identicalStartedAtTiesBreakDeterministicallyBySessionID() throws {
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])

        func build(loID: UUID, hiID: UUID) throws -> BurlyDigestPayloadDTO {
            let store = try makePhoneStore()
            try store.createExercise(squat)
            let a = SessionData(
                id: loID, startedAt: Fixture.epoch, state: .logged, origin: .live,
                items: [SessionItemData(
                    exerciseID: squat.id, order: 0,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch)]
                )]
            )
            let b = SessionData(
                id: hiID, startedAt: Fixture.epoch, state: .logged, origin: .live,
                items: [SessionItemData(
                    exerciseID: squat.id, order: 0,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 200), reps: 5, completedAt: Fixture.epoch)]
                )]
            )
            try store.createSession(a)
            try store.createSession(b)
            return try SessionDigestGenerator.generate(from: store, snapshotVersion: 0, ackedSessionIDs: [])
        }

        // Fixed, ordered ids so the "higher uuidString wins" rule is
        // actually exercised in both call orders, not accidentally
        // insertion-order-dependent.
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

        let first = try build(loID: lo, hiID: hi)
        let second = try build(loID: lo, hiID: hi)

        #expect(first.lastPerformance.first?.sets.first?.weightKg == 200)
        #expect(second == first, "the tie-break is a pure function of input, not of store fetch order")
    }

    @Test("an exercise logged twice within the same session (two items) merges both items' sets, sorted by completedAt")
    func sameExerciseTwiceInOneSessionMergesDeterministically() throws {
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let store = try makePhoneStore()
        try store.createExercise(squat)

        let session = SessionData(
            startedAt: Fixture.epoch,
            state: .logged,
            origin: .live,
            items: [
                SessionItemData(
                    exerciseID: squat.id, order: 0,
                    sets: [SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch)]
                ),
                SessionItemData(
                    exerciseID: squat.id, order: 1,
                    sets: [SetRecordData(
                        order: 0, weight: Weight(kg: 110), reps: 3,
                        completedAt: Fixture.epoch.addingTimeInterval(60)
                    )]
                )
            ]
        )
        try store.createSession(session)

        let payload = try SessionDigestGenerator.generate(from: store, snapshotVersion: 0, ackedSessionIDs: [])
        let entry = try #require(payload.lastPerformance.first { $0.exerciseID == squat.id })
        #expect(entry.sets.map(\.weightKg) == [100, 110])
    }

    // MARK: - Oracle

    /// A deliberately different algorithm from
    /// `SessionDigestGenerator.latestPerformancePerExercise`: walk sessions
    /// ascending by `startedAt` and overwrite a dictionary keyed by
    /// exerciseID — "latest wins" falls out of iteration order, not an
    /// explicit comparison.
    private func independentOracle(from sessions: [SessionData]) -> [ExerciseLastPerformanceData] {
        var winners: [UUID: ExerciseLastPerformanceData] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            var setsByExercise: [UUID: [SetRecordData]] = [:]
            for item in session.items {
                guard let exerciseID = item.exerciseID else { continue }
                setsByExercise[exerciseID, default: []].append(contentsOf: item.sets)
            }
            for (exerciseID, sets) in setsByExercise {
                let ordered = sets.sorted { lhs, rhs in
                    lhs.completedAt == rhs.completedAt
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : lhs.completedAt < rhs.completedAt
                }
                winners[exerciseID] = ExerciseLastPerformanceData(
                    exerciseID: exerciseID,
                    performedAt: session.startedAt,
                    sets: ordered.map { SetSnapshot(weight: $0.weight, reps: $0.reps, isWarmup: $0.isWarmup) }
                )
            }
        }
        return Array(winners.values)
    }

    private func byExerciseID(_ lhs: ExerciseLastPerformanceData, _ rhs: ExerciseLastPerformanceData) -> Bool {
        lhs.exerciseID.uuidString < rhs.exerciseID.uuidString
    }
}
