// SPDX-License-Identifier: GPL-3.0-or-later
// The §5 digest rides `updateApplicationContext`, which refuses a payload
// over roughly 64 KB. Before this bound, a heavy history (a multi-year Hevy
// import: hundreds of non-archived exercises) produced a digest that failed
// every publish, so the watch never saw another ack. These tests hold the
// generator to its bound: the watch's working set only, then a byte budget
// that keeps routine exercises and the most recently performed first, with
// every kept entry still exactly the full-history answer, the acks whole,
// and each routine's last-performed date carried for §2's "last done".
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
import BurlyFixtures
@testable import BurlyPhoneSync

@MainActor
@Suite("§5 digest bound — working set, byte budget, routine dates")
struct DigestPayloadBoundTests {

    // MARK: - Heavy history

    @Test("300 non-archived exercises over 3,600 sessions encode under 48 KB, routine exercises and the newest kept exactly")
    func heavyHistoryFitsTheBudget() throws {
        let seedStart = Date()
        let fixture = try HeavyHistory.seed()
        let seedSeconds = Date().timeIntervalSince(seedStart)
        let budget = SessionDigestGenerator.applicationContextByteBudget

        let generateStart = Date()
        let payload = try SessionDigestGenerator.generate(
            from: fixture.store,
            snapshotVersion: 7,
            ackedSessionIDs: fixture.ackedSessionIDs
        )
        let generateSeconds = Date().timeIntervalSince(generateStart)
        let size = try SessionDigestGenerator.envelopeByteCount(payload)

        // The reference: every working-set exercise's latest session, as the
        // fixture wrote it (an oracle independent of every store read),
        // untrimmed.
        let reference = fixture.expectedWorkingSetEntries
        let untrimmedSize = try SessionDigestGenerator.envelopeByteCount(BurlyDigestPayloadDTO(
            snapshotVersion: 7,
            lastPerformance: reference,
            ackedSessionIDs: payload.ackedSessionIDs,
            routineLastPerformed: payload.routineLastPerformed
        ))

        // Not vacuous: the working-set bound alone does not fit.
        #expect(reference.count == HeavyHistory.liveExerciseCount + 1)
        #expect(untrimmedSize > budget, "fixture too light to exercise the byte budget (\(untrimmedSize) bytes)")
        #expect(size <= budget, "digest envelope is \(size) bytes, over the \(budget)-byte budget")

        // Acks are never trimmed: they are what lets the watch prune.
        #expect(Set(payload.ackedSessionIDs) == fixture.ackedSessionIDs)
        // Every non-archived routine performed has its date.
        #expect(Set((payload.routineLastPerformed ?? []).map(\.routineID)) == fixture.routineIDs)

        // Every kept entry is exactly the full-history answer.
        var referenceByID: [UUID: ExerciseLastPerformanceData] = [:]
        for entry in reference { referenceByID[entry.exerciseID] = entry }
        for entry in payload.lastPerformance {
            #expect(referenceByID[entry.exerciseID] == entry)
        }
        let keptOrder: [String] = payload.lastPerformance.map { $0.exerciseID.uuidString }
        #expect(keptOrder == keptOrder.sorted())

        // Out-of-working-set exercises are never sent.
        let keptIDs = Set(payload.lastPerformance.map(\.exerciseID))
        #expect(keptIDs.isDisjoint(with: fixture.archivedUnusedExerciseIDs))

        // Routine exercises first, although they were performed earliest.
        #expect(fixture.routineExerciseIDs.isSubset(of: keptIDs))
        // Then the newest: nothing dropped is newer than anything kept.
        let keptOthers = payload.lastPerformance.filter { !fixture.routineExerciseIDs.contains($0.exerciseID) }
        let droppedOthers = reference.filter { !keptIDs.contains($0.exerciseID) }
        #expect(!droppedOthers.isEmpty)
        let oldestKept = try #require(keptOthers.map(\.performedAt).min())
        let newestDropped = try #require(droppedOthers.map(\.performedAt).max())
        #expect(newestDropped <= oldestKept)

        print("[digest bound] \(payload.lastPerformance.count) of \(reference.count) entries, \(payload.ackedSessionIDs.count) acks, \(payload.routineLastPerformed?.count ?? 0) routines: \(size) bytes (untrimmed \(untrimmedSize)); seed \(String(format: "%.2f", seedSeconds))s, generate \(String(format: "%.3f", generateSeconds))s")
    }

    // MARK: - The working set

    @Test("the digest leaves out archived exercises no live routine uses, though the snapshot carries the whole catalog")
    func onlyTheWatchWorkingSet() throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let retired = Fixture.exercise(name: "Retired")
        let stillUsed = Fixture.exercise(name: "Still Used")
        let archivedRoutineOnly = Fixture.exercise(name: "Archived Routine Only")
        for exercise in [bench, retired, stillUsed, archivedRoutineOnly] { try store.createExercise(exercise) }
        let live = Fixture.routine(name: "Live", over: [bench, stillUsed])
        let archived = Fixture.routine(name: "Archived", orderIndex: 1, over: [archivedRoutineOnly])
        try store.createRoutine(live)
        try store.createRoutine(archived)

        for (index, exercise) in [bench, retired, stillUsed, archivedRoutineOnly].enumerated() {
            try store.createSession(loggedSession(at: index, [(exercise, [100])]))
        }
        let later = Fixture.epoch.addingTimeInterval(86_400)
        for exercise in [retired, stillUsed, archivedRoutineOnly] {
            try store.archiveExercise(id: exercise.id, at: later)
        }
        try store.archiveRoutine(id: archived.id, at: later)

        let payload = try SessionDigestGenerator.generate(from: store, snapshotVersion: 1, ackedSessionIDs: [])
        let digestIDs: Set<UUID> = Set(payload.lastPerformance.map { $0.exerciseID })
        let expectedIDs: Set<UUID> = [bench.id, stillUsed.id]
        #expect(digestIDs == expectedIDs)

        // The snapshot is the other half of the split: since #49 it carries
        // the whole catalog, archived rows included, so an archive reaches
        // the watch's picker. The digest does not follow it there.
        let snapshot = try SnapshotPayloadBuilder.build(version: 1, from: store)
        let snapshotIDs: Set<UUID> = Set(snapshot.exercises.map { $0.id })
        let catalogIDs: Set<UUID> = [bench.id, retired.id, stillUsed.id, archivedRoutineOnly.id]
        #expect(snapshotIDs == catalogIDs)
    }

    // MARK: - Routine dates

    @Test("each stored routine's latest logged start is reported, archived ones too; deleted and never-performed routines are not")
    func routineDatesForStoredRoutines() throws {
        let store = try makePhoneStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        let push = Fixture.routine(name: "Push", over: [bench])
        let pull = Fixture.routine(name: "Pull", orderIndex: 1, over: [bench])
        let never = Fixture.routine(name: "Never", orderIndex: 2, over: [bench])
        let retired = Fixture.routine(name: "Retired", orderIndex: 3, over: [bench])
        let deleted = Fixture.routine(name: "Deleted", orderIndex: 4, over: [bench])
        for routine in [push, pull, never, retired, deleted] { try store.createRoutine(routine) }

        try store.createSession(Fixture.session(from: push, startedAt: Fixture.epoch))
        try store.createSession(Fixture.session(from: push, startedAt: Fixture.epoch.addingTimeInterval(86_400)))
        try store.createSession(Fixture.session(from: pull, startedAt: Fixture.epoch.addingTimeInterval(3_600)))
        try store.createSession(Fixture.session(from: retired, startedAt: Fixture.epoch))
        try store.createSession(Fixture.session(from: deleted, startedAt: Fixture.epoch))
        // Archived: the watch may still list it until the snapshot that
        // archives it arrives, which can be after this digest.
        try store.archiveRoutine(id: retired.id, at: Fixture.epoch.addingTimeInterval(7_200))
        // Deleted: its sessions keep the routine id, but there is no
        // routine left to show.
        try store.deleteRoutine(id: deleted.id)

        let payload = try SessionDigestGenerator.generate(from: store, snapshotVersion: 1, ackedSessionIDs: [])
        let pushDate: Date = Fixture.epoch.addingTimeInterval(86_400)
        let pullDate: Date = Fixture.epoch.addingTimeInterval(3_600)
        var expected: [BurlyRoutineLastPerformedDTO] = []
        expected.append(BurlyRoutineLastPerformedDTO(routineID: push.id, performedAt: pushDate))
        expected.append(BurlyRoutineLastPerformedDTO(routineID: pull.id, performedAt: pullDate))
        expected.append(BurlyRoutineLastPerformedDTO(routineID: retired.id, performedAt: Fixture.epoch))
        expected.sort { $0.routineID.uuidString < $1.routineID.uuidString }
        #expect(payload.routineLastPerformed == expected)
    }

    // MARK: - The budget, directly

    @Test("a payload that fits is returned unchanged")
    func fittingPayloadIsUntouched() throws {
        let payload = syntheticPayload(entryCount: 5, ackCount: 3)
        #expect(try SessionDigestGenerator.fitting(payload, within: 48 * 1024, routineExerciseIDs: []) == payload)
    }

    @Test("trimming keeps routine exercises, then the newest, stays sorted by id, and lands within the budget")
    func trimmingOrder() throws {
        let payload = syntheticPayload(entryCount: 40, ackCount: 3)
        // Entry i was performed i days after the epoch; make the two oldest
        // routine exercises.
        let byAge = payload.lastPerformance.sorted { $0.performedAt < $1.performedAt }
        let routineIDs: Set<UUID> = [byAge[0].exerciseID, byAge[1].exerciseID]
        let budget = try SessionDigestGenerator.envelopeByteCount(payload) / 2

        let trimmed = try SessionDigestGenerator.fitting(payload, within: budget, routineExerciseIDs: routineIDs)

        #expect(try SessionDigestGenerator.envelopeByteCount(trimmed) <= budget)
        #expect(trimmed.ackedSessionIDs == payload.ackedSessionIDs)
        #expect(trimmed.routineLastPerformed == payload.routineLastPerformed)
        #expect(trimmed.lastPerformance.count < payload.lastPerformance.count)
        let keptIDs: Set<UUID> = Set(trimmed.lastPerformance.map { $0.exerciseID })
        #expect(routineIDs.isSubset(of: keptIDs))
        let othersNewestFirst: [UUID] = byAge.dropFirst(2).reversed().map { $0.exerciseID }
        let expectedOthers: Set<UUID> = Set(othersNewestFirst.prefix(keptIDs.count - 2))
        #expect(expectedOthers == keptIDs.subtracting(routineIDs))
        let keptOrder: [String] = trimmed.lastPerformance.map { $0.exerciseID.uuidString }
        #expect(keptOrder == keptOrder.sorted())

        // Greedy and exact: one more entry would not have fit.
        let next = try #require(othersNewestFirst.dropFirst(keptIDs.count - 2).first)
        let nextEntry = try #require(payload.lastPerformance.first { $0.exerciseID == next })
        let oneMore = BurlyDigestPayloadDTO(
            snapshotVersion: trimmed.snapshotVersion,
            lastPerformance: trimmed.lastPerformance + [nextEntry],
            ackedSessionIDs: trimmed.ackedSessionIDs,
            routineLastPerformed: trimmed.routineLastPerformed
        )
        #expect(try SessionDigestGenerator.envelopeByteCount(oneMore) > budget)
    }

    @Test("acks and routine dates are never trimmed, even when they alone exceed the budget")
    func acksSurviveAnyBudget() throws {
        let payload = syntheticPayload(entryCount: 10, ackCount: 50)
        let trimmed = try SessionDigestGenerator.fitting(payload, within: 64, routineExerciseIDs: [])
        #expect(trimmed.lastPerformance.isEmpty)
        #expect(trimmed.ackedSessionIDs == payload.ackedSessionIDs)
        #expect(trimmed.routineLastPerformed == payload.routineLastPerformed)
    }

    @Test("an exercise whose latest session is being acknowledged outranks routines and recency, however old the workout")
    func acknowledgedLatestSessionsRankFirst() throws {
        let payload = syntheticPayload(entryCount: 40, ackCount: 3)
        let byAge = payload.lastPerformance.sorted { $0.performedAt < $1.performedAt }
        // The oldest entry's latest session is a months-old workout a watch
        // only just delivered: its ack is in this payload.
        let delivered = payload.ackedSessionIDs[0]
        let acknowledged = [byAge[0].exerciseID: delivered]
        let routineIDs: Set<UUID> = [byAge[1].exerciseID]
        // Room for roughly two entries beyond the acks and routine dates.
        let base = try SessionDigestGenerator.envelopeByteCount(BurlyDigestPayloadDTO(
            snapshotVersion: payload.snapshotVersion,
            lastPerformance: [],
            ackedSessionIDs: payload.ackedSessionIDs,
            routineLastPerformed: payload.routineLastPerformed
        ))
        let encoder = JSONEncoder()
        let firstSize: Int = try encoder.encode(byAge[0]).count
        let secondSize: Int = try encoder.encode(byAge[1]).count
        let entrySize: Int = firstSize + secondSize + 1
        let trimmed = try SessionDigestGenerator.fitting(
            payload,
            within: base + entrySize,
            routineExerciseIDs: routineIDs,
            acknowledgedLatestSession: acknowledged
        )

        let expectedIDs: Set<UUID> = [byAge[0].exerciseID, byAge[1].exerciseID]
        #expect(Set(trimmed.lastPerformance.map { $0.exerciseID }) == expectedIDs)
        #expect(trimmed.ackedSessionIDs == payload.ackedSessionIDs, "every entry an ack needed fit, so no ack is held back")
    }

    @Test("an acknowledged session whose numbers cannot fit keeps its ack back, so the watch does not prune it without them")
    func unfittableAcknowledgedSessionHoldsItsAck() throws {
        let payload = syntheticPayload(entryCount: 10, ackCount: 3)
        let delivered = payload.ackedSessionIDs[1]
        var acknowledged: [UUID: UUID] = [:]
        for entry in payload.lastPerformance.prefix(4) { acknowledged[entry.exerciseID] = delivered }

        let trimmed = try SessionDigestGenerator.fitting(
            payload,
            within: 64,
            routineExerciseIDs: [],
            acknowledgedLatestSession: acknowledged
        )

        #expect(trimmed.lastPerformance.isEmpty)
        let remainingAcks: [UUID] = payload.ackedSessionIDs.filter { $0 != delivered }
        #expect(trimmed.ackedSessionIDs == remainingAcks)
        #expect(trimmed.routineLastPerformed == payload.routineLastPerformed)
    }

    @Test("generate holds back the ack of a heavy session whose numbers outgrow the budget, and acks it once they fit")
    func generateHoldsBackAnAckUntilItsNumbersFit() throws {
        let store = try makePhoneStore()
        var exercises: [ExerciseData] = []
        for index in 0..<12 { exercises.append(Fixture.exercise(name: "Exercise \(index)")) }
        for exercise in exercises { try store.createExercise(exercise) }
        let weights: [Double] = [100, 105, 110, 115, 120]
        var sessionEntries: [(ExerciseData, [Double])] = []
        for exercise in exercises { sessionEntries.append((exercise, weights)) }
        let delivered = loggedSession(at: 0, sessionEntries)
        try store.createSession(delivered)
        let other = UUID()
        let bothAcks: Set<UUID> = [delivered.id, other]

        let full = try SessionDigestGenerator.generate(from: store, snapshotVersion: 1, ackedSessionIDs: bothAcks)
        let fullSize = try SessionDigestGenerator.envelopeByteCount(full)
        #expect(full.lastPerformance.count == 12)
        #expect(Set(full.ackedSessionIDs) == bothAcks)

        let tight = try SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: 1,
            ackedSessionIDs: bothAcks,
            byteBudget: fullSize - 1
        )
        #expect(tight.lastPerformance.count == 11)
        #expect(tight.ackedSessionIDs == [other], "the delivered session waits for a digest that can carry all its numbers")
    }

    // MARK: - Helpers

    // Loops and typed locals, not chained `map`/`sorted` closures: the
    // hosted Xcode 26.6 gave up type-checking the chained form ("unable to
    // type-check this expression in reasonable time").
    private func syntheticPayload(entryCount: Int, ackCount: Int) -> BurlyDigestPayloadDTO {
        var entries: [ExerciseLastPerformanceData] = []
        for index in 0..<entryCount {
            var sets: [SetSnapshot] = []
            for setIndex in 0..<(1 + index % 5) {
                let pounds: Double = Double(45 + 10 * setIndex)
                sets.append(SetSnapshot(weight: Weight(pounds: pounds), reps: 8))
            }
            let performedAt: Date = Fixture.epoch.addingTimeInterval(Double(index) * 86_400)
            entries.append(ExerciseLastPerformanceData(exerciseID: UUID(), performedAt: performedAt, sets: sets))
        }
        entries.sort { $0.exerciseID.uuidString < $1.exerciseID.uuidString }

        var ackedSessionIDs: [UUID] = []
        for _ in 0..<ackCount { ackedSessionIDs.append(UUID()) }
        ackedSessionIDs.sort { $0.uuidString < $1.uuidString }

        let routineDates: [BurlyRoutineLastPerformedDTO] = [
            BurlyRoutineLastPerformedDTO(routineID: UUID(), performedAt: Fixture.epoch)
        ]
        return BurlyDigestPayloadDTO(
            snapshotVersion: 3,
            lastPerformance: entries,
            ackedSessionIDs: ackedSessionIDs,
            routineLastPerformed: routineDates
        )
    }

    private func loggedSession(at hours: Int, _ items: [(ExerciseData, [Double])]) -> SessionData {
        let startedAt: Date = Fixture.epoch.addingTimeInterval(Double(hours) * 3_600)
        var sessionItems: [SessionItemData] = []
        for (index, entry) in items.enumerated() {
            var sets: [SetRecordData] = []
            for (order, kg) in entry.1.enumerated() {
                sets.append(SetRecordData(order: order, weight: Weight(kg: kg), reps: 5, completedAt: startedAt))
            }
            sessionItems.append(SessionItemData(exerciseID: entry.0.id, order: index, sets: sets))
        }
        return SessionData(startedAt: startedAt, state: .logged, origin: .live, items: sessionItems)
    }
}

/// A multi-year, Hevy-shaped phone history: 300 non-archived exercises
/// (Hevy imports its exercises non-archived), 3,600 daily sessions with
/// pound-converted weights (the long decimals a pounds lifter's history
/// encodes as), three routines whose 24 exercises were all performed
/// earliest, five archived exercises no routine uses, one archived exercise
/// a routine still uses, and 120 acks (four delivered sessions a day for
/// §5's whole 30-day retention, well above real use).
@MainActor
private struct HeavyHistory {
    static let liveExerciseCount = 300
    static let sessionCount = 3_600

    let store: SwiftDataStore
    let routineIDs: Set<UUID>
    let routineExerciseIDs: Set<UUID>
    let archivedUnusedExerciseIDs: Set<UUID>
    let ackedSessionIDs: Set<UUID>
    /// Each working-set exercise's latest session as written, sorted by
    /// exercise id: what the full-history derivation must produce.
    let expectedWorkingSetEntries: [ExerciseLastPerformanceData]

    // Loops and typed locals throughout: the fixture is the most
    // expression-dense helper in the file, and the hosted Xcode 26.6 gives
    // up on nested `map` closures that Xcode 27 accepts. The random draws
    // happen in the same order as the closure form did (set count, then each
    // set's weight, then its reps), so the seeded history is unchanged.
    static func seed() throws -> HeavyHistory {
        var rng = SeededGenerator(seed: 0xD1_6E57)
        let store = try makePhoneStore()

        var live: [ExerciseData] = []
        for index in 0..<liveExerciseCount {
            live.append(Fixture.exercise(name: "Imported \(index)", origin: .hevyImport))
        }
        var archivedUnused: [ExerciseData] = []
        for index in 0..<5 {
            archivedUnused.append(Fixture.exercise(name: "Retired \(index)", origin: .hevyImport))
        }
        let archivedInRoutine = Fixture.exercise(name: "Retired but planned", origin: .hevyImport)
        var everyExercise: [ExerciseData] = live
        everyExercise.append(contentsOf: archivedUnused)
        everyExercise.append(archivedInRoutine)
        for exercise in everyExercise { try store.createExercise(exercise) }

        // Routine exercises: the first 24, plus the archived one in Legs.
        let routineNames: [String] = ["Push", "Pull", "Legs"]
        var routines: [RoutineData] = []
        for index in 0..<3 {
            var routineExercises: [ExerciseData] = Array(live[(index * 8)..<(index * 8 + 8)])
            if index == 2 { routineExercises.append(archivedInRoutine) }
            routines.append(Fixture.routine(name: routineNames[index], orderIndex: index, over: routineExercises))
        }
        for routine in routines { try store.createRoutine(routine) }

        // One session a day. The first 300 days visit every exercise once,
        // in order, so the routine exercises (0..<24) and the extra ones are
        // the oldest; after that only exercises 24..<300 recur, one a day.
        // Days are distinct and each session names an exercise once, so the
        // last session written for an exercise is its latest.
        var extras: [ExerciseData] = [archivedInRoutine]
        extras.append(contentsOf: archivedUnused)
        var latest: [UUID: ExerciseLastPerformanceData] = [:]
        for day in 0..<sessionCount {
            let startedAt: Date = Fixture.epoch.addingTimeInterval(Double(day) * 86_400)
            var exercises: [ExerciseData] = []
            if day < liveExerciseCount {
                exercises.append(live[day])
                if day < extras.count { exercises.append(extras[day]) }
            } else {
                exercises.append(live[24 + (day % (liveExerciseCount - 24))])
            }
            let firstExerciseID: UUID = exercises[0].id
            var routine: RoutineData?
            for candidate in routines {
                var usesExercise = false
                for item in candidate.items where item.exerciseID == firstExerciseID { usesExercise = true }
                if usesExercise {
                    routine = candidate
                    break
                }
            }

            var items: [SessionItemData] = []
            for (order, exercise) in exercises.enumerated() {
                let setCount: Int = Int.random(in: 4...5, using: &rng)
                var sets: [SetRecordData] = []
                for setIndex in 0..<setCount {
                    let fiveLbSteps: Int = Int.random(in: 9...63, using: &rng)
                    let reps: Int = Int.random(in: 3...12, using: &rng)
                    let completedAt: Date = startedAt.addingTimeInterval(Double(setIndex) * 150)
                    sets.append(SetRecordData(
                        order: setIndex,
                        weight: Weight(pounds: Double(fiveLbSteps * 5)),
                        reps: reps,
                        isWarmup: setIndex == 0,
                        completedAt: completedAt
                    ))
                }
                items.append(SessionItemData(exerciseID: exercise.id, order: order, sets: sets))
            }
            try store.createSession(SessionData(
                routineID: routine?.id,
                routineName: routine?.name,
                startedAt: startedAt,
                state: .logged,
                origin: .hevyImport,
                items: items
            ))
            for item in items {
                guard let exerciseID = item.exerciseID else { continue }
                var snapshots: [SetSnapshot] = []
                for set in item.sets {
                    snapshots.append(SetSnapshot(weight: set.weight, reps: set.reps, isWarmup: set.isWarmup))
                }
                latest[exerciseID] = ExerciseLastPerformanceData(
                    exerciseID: exerciseID,
                    performedAt: startedAt,
                    sets: snapshots
                )
            }
        }

        let later: Date = Fixture.epoch.addingTimeInterval(Double(sessionCount) * 86_400)
        var toArchive: [ExerciseData] = archivedUnused
        toArchive.append(archivedInRoutine)
        for exercise in toArchive {
            try store.archiveExercise(id: exercise.id, at: later)
        }

        var workingSet = Set<UUID>()
        for exercise in live { workingSet.insert(exercise.id) }
        workingSet.insert(archivedInRoutine.id)

        var expectedEntries: [ExerciseLastPerformanceData] = []
        for entry in latest.values where workingSet.contains(entry.exerciseID) {
            expectedEntries.append(entry)
        }
        expectedEntries.sort { $0.exerciseID.uuidString < $1.exerciseID.uuidString }

        var routineIDs = Set<UUID>()
        var routineExerciseIDs = Set<UUID>()
        for routine in routines {
            routineIDs.insert(routine.id)
            for item in routine.items {
                if let exerciseID = item.exerciseID { routineExerciseIDs.insert(exerciseID) }
            }
        }
        var archivedUnusedIDs = Set<UUID>()
        for exercise in archivedUnused { archivedUnusedIDs.insert(exercise.id) }
        var ackedSessionIDs = Set<UUID>()
        for _ in 0..<120 { ackedSessionIDs.insert(UUID()) }

        return HeavyHistory(
            store: store,
            routineIDs: routineIDs,
            routineExerciseIDs: routineExerciseIDs,
            archivedUnusedExerciseIDs: archivedUnusedIDs,
            ackedSessionIDs: ackedSessionIDs,
            expectedWorkingSetEntries: expectedEntries
        )
    }
}
