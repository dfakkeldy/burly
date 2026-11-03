// SPDX-License-Identifier: GPL-3.0-or-later
// Issue #24 — `latestLoggedSetSlices(forExercises:)`, the digest generator's
// narrow read, held to the full-history answer it replaces, case by case:
// empty, latest-empty, tie, repeated, nil, active, archived and corrupt.
// Plus `routineLastPerformedDates()`, which carries §2's "last done" across
// the watch's prune.
//
// The reference answer is `LatestLoggedSession.winningSlices(from:
// allLoggedSetSlices(), forExercises:)`: the derivation over every logged
// set, which is also the protocol's fallback implementation. Slices are
// compared as sets because neither read promises an order.
import Foundation
import SwiftData
import Testing
import BurlyCore
import BurlySync
import BurlyFixtures
@testable import BurlyPersistence

@MainActor
@Suite("#24 — latestLoggedSetSlices: the narrow digest read equals full history")
struct LatestLoggedSetSlicesTests {

    // MARK: - The eight cases

    @Test("an empty store, and an empty request, both return nothing")
    func emptyStoreAndEmptyRequest() throws {
        let store = try makeStore()
        #expect(try store.latestLoggedSetSlices(forExercises: [UUID()]).isEmpty)

        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(session(at: 0, [(bench, [100])]))
        #expect(try store.latestLoggedSetSlices(forExercises: []).isEmpty)
        try expectMatchesFullHistory(store, [bench.id])
    }

    @Test("only the latest session's sets come back, from every requested exercise, and nothing unrequested")
    func latestSessionPerRequestedExercise() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        for exercise in [bench, row, squat] { try store.createExercise(exercise) }

        try store.createSession(session(at: 0, [(bench, [100, 105]), (row, [60])]))
        let latest = session(at: 1, [(bench, [110, 112.5, 115])])
        try store.createSession(latest)
        try store.createSession(session(at: 2, [(squat, [140])]))

        let slices = try store.latestLoggedSetSlices(forExercises: [bench.id, row.id])
        #expect(Set(slices.filter { $0.exerciseID == bench.id }.map(\.set.weight.kg)) == [110, 112.5, 115])
        #expect(slices.filter { $0.exerciseID == bench.id }.allSatisfy { $0.sessionID == latest.id })
        #expect(slices.filter { $0.exerciseID == row.id }.map(\.set.weight.kg) == [60])
        #expect(slices.allSatisfy { $0.exerciseID != squat.id })
        try expectMatchesFullHistory(store, [bench.id, row.id])
    }

    @Test("latest-empty: a newer session whose item for the exercise has no sets does not win")
    func latestSessionWithNoSetsFallsBack() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        try store.createExercise(bench)
        try store.createExercise(row)

        let older = session(at: 0, [(bench, [100])])
        try store.createSession(older)
        // Bench was on the plan but skipped; only Row got sets.
        try store.createSession(session(at: 1, [(bench, []), (row, [60])]))

        let slices = try store.latestLoggedSetSlices(forExercises: [bench.id])
        #expect(slices.map(\.sessionID) == [older.id])
        #expect(slices.map(\.set.weight.kg) == [100])
        try expectMatchesFullHistory(store, [bench.id, row.id])
    }

    @Test("an exact startedAt tie goes to the higher session id, whichever was stored first")
    func tieGoesToHigherSessionID() throws {
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        for order in [[lo, hi], [hi, lo]] {
            let store = try makeStore()
            let bench = Fixture.exercise(name: "Bench Press")
            try store.createExercise(bench)
            for id in order {
                try store.createSession(session(id: id, at: 0, [(bench, [id == hi ? 200 : 100])]))
            }
            let slices = try store.latestLoggedSetSlices(forExercises: [bench.id])
            #expect(slices.map(\.sessionID) == [hi])
            #expect(slices.map(\.set.weight.kg) == [200])
            try expectMatchesFullHistory(store, [bench.id])
        }
    }

    @Test("the same exercise twice in the winning session returns both items' sets")
    func repeatedExerciseReturnsBothItems() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.createSession(session(at: 0, [(bench, [90])]))
        let latest = session(at: 1, [(bench, [100, 102.5]), (bench, [80])])
        try store.createSession(latest)

        let slices = try store.latestLoggedSetSlices(forExercises: [bench.id])
        #expect(slices.count == 3)
        #expect(slices.allSatisfy { $0.sessionID == latest.id })
        #expect(Set(slices.map(\.set.weight.kg)) == [100, 102.5, 80])
        try expectMatchesFullHistory(store, [bench.id])
    }

    @Test("an item with no exercise never contributes and never fails the read")
    func nilExerciseIsIgnored() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let older = session(at: 0, [(bench, [100])])
        try store.createSession(older)
        try store.createSession(SessionData(
            startedAt: Fixture.epoch.addingTimeInterval(3_600),
            state: .logged,
            origin: .live,
            items: [SessionItemData(
                exerciseID: nil,
                order: 0,
                sets: [SetRecordData(order: 0, weight: Weight(kg: 40), reps: 10, completedAt: Fixture.epoch)]
            )]
        ))

        let slices = try store.latestLoggedSetSlices(forExercises: [bench.id])
        #expect(slices.map(\.sessionID) == [older.id])
        #expect(slices.allSatisfy { $0.exerciseID == bench.id })
        try expectMatchesFullHistory(store, [bench.id])
    }

    @Test("a newer .active session is not history and never wins")
    func activeSessionIsIgnored() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)
        let logged = session(at: 0, [(bench, [100])])
        try store.createSession(logged)

        var active = Fixture.activeSession(from: routine, startedAt: Fixture.epoch.addingTimeInterval(3_600))
        try SessionMutator.logSet(
            itemID: try #require(active.items.first?.id),
            weight: Weight(kg: 999), reps: 1, in: &active, clock: TestClock()
        )
        try store.saveActiveSession(active)

        let slices = try store.latestLoggedSetSlices(forExercises: [bench.id])
        #expect(slices.map(\.sessionID) == [logged.id])
        try expectMatchesFullHistory(store, [bench.id])
    }

    @Test("an archived exercise's history is returned when asked for; archive state is the caller's filter")
    func archivedExerciseIsReturnedWhenRequested() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let logged = session(at: 0, [(bench, [100])])
        try store.createSession(logged)
        try store.archiveExercise(id: bench.id, at: Fixture.epoch.addingTimeInterval(7_200))

        #expect(try store.latestLoggedSetSlices(forExercises: [bench.id]).map(\.sessionID) == [logged.id])
        try expectMatchesFullHistory(store, [bench.id])
    }

    @Test("a corrupt stored weight throws when it is in a winning session, and cannot fail the read from a losing one")
    func corruptWeightIsStrictOnlyWhereRead() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let oldBenchSetID = UUID()
        let latestRowSetID = UUID()
        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createExercise(row)
            try store.createSession(session(at: 0, [(bench, [100])], setIDs: [oldBenchSetID]))
            try store.createSession(session(at: 1, [(bench, [110])]))
            try store.createSession(session(at: 2, [(row, [60])], setIDs: [latestRowSetID]))
        }
        try corruptWeight(ofSet: oldBenchSetID, in: url)
        try corruptWeight(ofSet: latestRowSetID, in: url)

        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))
        // Bench's corrupt set is in a session that lost to a newer one.
        #expect(try reloaded.latestLoggedSetSlices(forExercises: [bench.id]).map(\.set.weight.kg) == [110])
        // Row's corrupt set is the one the digest would carry.
        #expect(throws: BurlyStoreError.corruptedWeight(id: latestRowSetID, underlying: .negative(-1))) {
            try reloaded.latestLoggedSetSlices(forExercises: [row.id])
        }
    }

    // MARK: - Randomized equivalence

    @Test(
        "for randomized histories with deletions, ties, empty items and repeats, the narrow read equals full history",
        arguments: Array(0..<20 as Range<UInt64>)
    )
    func randomizedHistoriesMatchFullHistory(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        let store = try makeStore()
        let exercises = (0..<5).map { Fixture.exercise(name: "Exercise \($0)") }
        for exercise in exercises { try store.createExercise(exercise) }

        for _ in 0..<Int.random(in: 0...16, using: &rng) {
            // Few distinct hours, so startedAt ties are common.
            let hour = Int.random(in: 0..<6, using: &rng)
            var items: [(ExerciseData, [Double])] = []
            for exercise in exercises where Bool.random(using: &rng) {
                let setCount = Int.random(in: 0...3, using: &rng)
                items.append((exercise, (0..<setCount).map { _ in Double(Int.random(in: 4...40, using: &rng) * 5) }))
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    items.append((exercise, [Double(Int.random(in: 4...40, using: &rng) * 5)]))
                }
            }
            let created = session(at: hour, items)
            try store.createSession(created)
            if Int.random(in: 0..<4, using: &rng) == 0 {
                try store.deleteSession(id: created.id)
            }
        }

        let requested = Set(exercises.filter { _ in Int.random(in: 0..<4, using: &rng) != 0 }.map(\.id))
        try expectMatchesFullHistory(store, requested)
    }

    // MARK: - Helpers

    private func expectMatchesFullHistory(
        _ store: SwiftDataStore,
        _ exerciseIDs: Set<UUID>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let narrow = try store.latestLoggedSetSlices(forExercises: exerciseIDs)
        let reference = LatestLoggedSession.winningSlices(
            from: try store.allLoggedSetSlices(),
            forExercises: exerciseIDs
        )
        #expect(narrow.count == reference.count, sourceLocation: sourceLocation)
        #expect(Set(narrow) == Set(reference), sourceLocation: sourceLocation)
    }

    /// A logged session `hours` after the epoch, one item per entry, each
    /// set at that entry's weights in order.
    private func session(
        id: UUID = UUID(),
        at hours: Int,
        _ items: [(ExerciseData, [Double])],
        setIDs: [UUID] = []
    ) -> SessionData {
        let startedAt = Fixture.epoch.addingTimeInterval(Double(hours) * 3_600)
        var remainingSetIDs = setIDs[...]
        return SessionData(
            id: id,
            startedAt: startedAt,
            state: .logged,
            origin: .live,
            items: items.enumerated().map { index, entry in
                SessionItemData(
                    exerciseID: entry.0.id,
                    order: index,
                    sets: entry.1.enumerated().map { order, kg in
                        SetRecordData(
                            id: remainingSetIDs.popFirst() ?? UUID(),
                            order: order,
                            weight: Weight(kg: kg),
                            reps: 5,
                            completedAt: startedAt.addingTimeInterval(Double(order) * 60)
                        )
                    }
                )
            }
        )
    }

    /// Reaches past the store to write a weight no store API can, the way
    /// `StoreAPISurfaceTests.corruptedStoredWeightFailsClosedOnColdReload` does.
    private func corruptWeight(ofSet setID: UUID, in url: URL) throws {
        let context = ModelContext(try BurlyContainer.phone(at: .file(url)))
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<SetRecord>(predicate: #Predicate { $0.id == setID })
        descriptor.fetchLimit = 1
        let stored = try #require(try context.fetch(descriptor).first)
        stored.weightKg = -1
        try context.save()
    }
}

// MARK: - Routine last-performed dates

@MainActor
@Suite("§2 last done — routineLastPerformedDates survives the watch's prune")
struct RoutineLastPerformedDatesTests {

    @Test("a phone store reports each routine's latest logged start, ignoring active and routine-less sessions")
    func phoneDerivesFromHistory() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let push = Fixture.routine(name: "Push", over: [bench])
        let pull = Fixture.routine(name: "Pull", orderIndex: 1, over: [bench])
        let never = Fixture.routine(name: "Legs", orderIndex: 2, over: [bench])
        try store.createExercise(bench)
        for routine in [push, pull, never] { try store.createRoutine(routine) }

        try store.createSession(Fixture.session(from: push, startedAt: Fixture.epoch))
        try store.createSession(Fixture.session(from: push, startedAt: Fixture.epoch.addingTimeInterval(86_400)))
        try store.createSession(Fixture.session(from: pull, startedAt: Fixture.epoch.addingTimeInterval(3_600)))
        try store.createSession(SessionData(
            startedAt: Fixture.epoch.addingTimeInterval(9 * 86_400), state: .logged, origin: .live, items: []
        ))
        try store.saveActiveSession(Fixture.activeSession(from: pull, startedAt: Fixture.epoch.addingTimeInterval(5 * 86_400)))

        #expect(try store.routineLastPerformedDates() == [
            push.id: Fixture.epoch.addingTimeInterval(86_400),
            pull.id: Fixture.epoch.addingTimeInterval(3_600)
        ])
    }

    @Test("a watch store keeps the phone's reported date after pruning the session, and prefers a newer unacknowledged one")
    func watchMergesDigestDatesWithUnackedSessions() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        let push = Fixture.routine(name: "Push", over: [bench])
        let pull = Fixture.routine(name: "Pull", orderIndex: 1, over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(push)
        try store.createRoutine(pull)

        let delivered = Fixture.session(from: push, startedAt: Fixture.epoch)
        try store.createSession(delivered)
        #expect(try store.routineLastPerformedDates() == [push.id: Fixture.epoch])

        // The phone acknowledges it and reports Push and Pull (Pull from
        // phone-side history the watch never held).
        try store.applyWatchDigest(BurlyDigestPayloadDTO(
            snapshotVersion: 0,
            lastPerformance: [],
            ackedSessionIDs: [delivered.id],
            routineLastPerformed: [
                BurlyRoutineLastPerformedDTO(routineID: push.id, performedAt: Fixture.epoch),
                BurlyRoutineLastPerformedDTO(routineID: pull.id, performedAt: Fixture.epoch.addingTimeInterval(-86_400))
            ]
        ))
        #expect(try store.session(id: delivered.id) == nil, "the acknowledged session is pruned")
        #expect(try store.routineLastPerformedDates() == [
            push.id: Fixture.epoch,
            pull.id: Fixture.epoch.addingTimeInterval(-86_400)
        ])

        // Finished on the watch, not yet acknowledged: newer than the report.
        let fresh = Fixture.session(from: pull, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        try store.createSession(fresh)
        #expect(try store.routineLastPerformedDates()[pull.id] == Fixture.epoch.addingTimeInterval(86_400))
    }

    @Test("the reported dates are replaced whole by each digest, and survive a cold reopen")
    func reportedDatesReplaceAndPersist() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let push = UUID()
        let pull = UUID()
        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url))
            try store.applyWatchDigest(digest([push: Fixture.epoch, pull: Fixture.epoch]))
            // The phone deleted Pull's only session: it is no longer reported.
            try store.applyWatchDigest(digest([push: Fixture.epoch.addingTimeInterval(60)]))
        }
        let reopened = try SwiftDataStore(kind: .watch, at: .file(url))
        #expect(try reopened.routineLastPerformedDates() == [push: Fixture.epoch.addingTimeInterval(60)])
        #expect(try reopened.watchSyncState().routineLastPerformedAt == [push: Fixture.epoch.addingTimeInterval(60)])
    }

    @Test("applyDigest, which carries no routine dates, leaves the reported ones alone")
    func applyDigestLeavesReportedDates() throws {
        let store = try makeStore(.watch)
        let push = UUID()
        try store.applyWatchDigest(digest([push: Fixture.epoch]))
        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [])
        #expect(try store.routineLastPerformedDates() == [push: Fixture.epoch])
    }

    @Test("a digest without routine dates (an older phone) still keeps a pruned session's last-done date")
    func pruneFoldsTheSessionDateWhenThePhoneReportsNone() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        let push = Fixture.routine(name: "Push", over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(push)
        let older = UUID()
        try store.applyWatchDigest(digest([push.id: Fixture.epoch, older: Fixture.epoch]))

        let delivered = Fixture.session(from: push, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        try store.createSession(delivered)
        try store.applyWatchDigest(BurlyDigestPayloadDTO(
            snapshotVersion: 0, lastPerformance: [], ackedSessionIDs: [delivered.id]
        ))

        #expect(try store.session(id: delivered.id) == nil, "the acknowledged session is pruned")
        #expect(try store.routineLastPerformedDates() == [
            push.id: Fixture.epoch.addingTimeInterval(86_400),
            older: Fixture.epoch
        ])
    }

    @Test("two dates for one routine reject the whole digest, acks and all")
    func duplicateRoutineRejectsDigest() throws {
        let store = try makeStore(.watch)
        let bench = Fixture.exercise(name: "Bench Press")
        let push = Fixture.routine(name: "Push", over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(push)
        let delivered = Fixture.session(from: push)
        try store.createSession(delivered)

        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: 0,
            lastPerformance: [],
            ackedSessionIDs: [delivered.id],
            routineLastPerformed: [
                BurlyRoutineLastPerformedDTO(routineID: push.id, performedAt: Fixture.epoch),
                BurlyRoutineLastPerformedDTO(routineID: push.id, performedAt: Fixture.epoch.addingTimeInterval(60))
            ]
        )
        #expect(throws: BurlyStoreError.duplicateID(push.id)) {
            try store.applyWatchDigest(payload)
        }
        #expect(try store.session(id: delivered.id) != nil, "nothing was pruned")
        #expect(try store.watchSyncState().routineLastPerformedAt.isEmpty)
    }

    @Test("a journal written before routine dates existed reads them as empty")
    func preRoutineDatesJournalReadsEmpty() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let seedContext = ModelContext(container)
        let legacy = #"{"schemaVersion":1,"lastAppliedSnapshotVersion":7,"lastAckedSessionIDs":[],"displayUnit":"lb","restDefault":120}"#
        seedContext.insert(WatchSyncJournal(payload: Data(legacy.utf8)))
        try seedContext.save()

        let state = try SwiftDataStore(container: container).watchSyncState()
        #expect(state.lastAppliedSnapshotVersion == 7)
        #expect(state.displayUnit == .pounds)
        #expect(state.routineLastPerformedAt.isEmpty)
    }

    private func digest(_ dates: [UUID: Date]) -> BurlyDigestPayloadDTO {
        BurlyDigestPayloadDTO(
            snapshotVersion: 0,
            lastPerformance: [],
            ackedSessionIDs: [],
            routineLastPerformed: dates.map { BurlyRoutineLastPerformedDTO(routineID: $0.key, performedAt: $0.value) }
        )
    }
}
