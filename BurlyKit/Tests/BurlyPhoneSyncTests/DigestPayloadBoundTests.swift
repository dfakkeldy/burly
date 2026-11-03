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
        let referenceByID = Dictionary(uniqueKeysWithValues: reference.map { ($0.exerciseID, $0) })
        for entry in payload.lastPerformance {
            #expect(referenceByID[entry.exerciseID] == entry)
        }
        #expect(payload.lastPerformance.map(\.exerciseID.uuidString)
            == payload.lastPerformance.map(\.exerciseID.uuidString).sorted())

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

    @Test("archived exercises outside every live routine are left out; one a live routine still uses stays")
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
        #expect(Set(payload.lastPerformance.map(\.exerciseID)) == [bench.id, stillUsed.id])
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
        #expect(payload.routineLastPerformed == [
            BurlyRoutineLastPerformedDTO(routineID: push.id, performedAt: Fixture.epoch.addingTimeInterval(86_400)),
            BurlyRoutineLastPerformedDTO(routineID: pull.id, performedAt: Fixture.epoch.addingTimeInterval(3_600)),
            BurlyRoutineLastPerformedDTO(routineID: retired.id, performedAt: Fixture.epoch)
        ].sorted { $0.routineID.uuidString < $1.routineID.uuidString })
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
        let keptIDs = Set(trimmed.lastPerformance.map(\.exerciseID))
        #expect(routineIDs.isSubset(of: keptIDs))
        let othersNewestFirst = byAge.dropFirst(2).reversed().map(\.exerciseID)
        #expect(Set(othersNewestFirst.prefix(keptIDs.count - 2)) == keptIDs.subtracting(routineIDs))
        #expect(trimmed.lastPerformance.map(\.exerciseID.uuidString)
            == trimmed.lastPerformance.map(\.exerciseID.uuidString).sorted())

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
        let entrySize = try JSONEncoder().encode(byAge[0]).count + JSONEncoder().encode(byAge[1]).count + 1
        let trimmed = try SessionDigestGenerator.fitting(
            payload,
            within: base + entrySize,
            routineExerciseIDs: routineIDs,
            acknowledgedLatestSession: acknowledged
        )

        #expect(Set(trimmed.lastPerformance.map(\.exerciseID)) == [byAge[0].exerciseID, byAge[1].exerciseID])
        #expect(trimmed.ackedSessionIDs == payload.ackedSessionIDs, "every entry an ack needed fit, so no ack is held back")
    }

    @Test("an acknowledged session whose numbers cannot fit keeps its ack back, so the watch does not prune it without them")
    func unfittableAcknowledgedSessionHoldsItsAck() throws {
        let payload = syntheticPayload(entryCount: 10, ackCount: 3)
        let delivered = payload.ackedSessionIDs[1]
        let acknowledged = Dictionary(uniqueKeysWithValues: payload.lastPerformance.prefix(4).map { ($0.exerciseID, delivered) })

        let trimmed = try SessionDigestGenerator.fitting(
            payload,
            within: 64,
            routineExerciseIDs: [],
            acknowledgedLatestSession: acknowledged
        )

        #expect(trimmed.lastPerformance.isEmpty)
        #expect(trimmed.ackedSessionIDs == payload.ackedSessionIDs.filter { $0 != delivered })
        #expect(trimmed.routineLastPerformed == payload.routineLastPerformed)
    }

    @Test("generate holds back the ack of a heavy session whose numbers outgrow the budget, and acks it once they fit")
    func generateHoldsBackAnAckUntilItsNumbersFit() throws {
        let store = try makePhoneStore()
        let exercises = (0..<12).map { Fixture.exercise(name: "Exercise \($0)") }
        for exercise in exercises { try store.createExercise(exercise) }
        let delivered = loggedSession(at: 0, exercises.map { ($0, [100, 105, 110, 115, 120]) })
        try store.createSession(delivered)
        let other = UUID()

        let full = try SessionDigestGenerator.generate(from: store, snapshotVersion: 1, ackedSessionIDs: [delivered.id, other])
        let fullSize = try SessionDigestGenerator.envelopeByteCount(full)
        #expect(full.lastPerformance.count == 12)
        #expect(Set(full.ackedSessionIDs) == [delivered.id, other])

        let tight = try SessionDigestGenerator.generate(
            from: store,
            snapshotVersion: 1,
            ackedSessionIDs: [delivered.id, other],
            byteBudget: fullSize - 1
        )
        #expect(tight.lastPerformance.count == 11)
        #expect(tight.ackedSessionIDs == [other], "the delivered session waits for a digest that can carry all its numbers")
    }

    // MARK: - Helpers

    private func syntheticPayload(entryCount: Int, ackCount: Int) -> BurlyDigestPayloadDTO {
        let entries = (0..<entryCount).map { index in
            ExerciseLastPerformanceData(
                exerciseID: UUID(),
                performedAt: Fixture.epoch.addingTimeInterval(Double(index) * 86_400),
                sets: (0..<(1 + index % 5)).map { SetSnapshot(weight: Weight(pounds: Double(45 + 10 * $0)), reps: 8) }
            )
        }
        .sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
        return BurlyDigestPayloadDTO(
            snapshotVersion: 3,
            lastPerformance: entries,
            ackedSessionIDs: (0..<ackCount).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString },
            routineLastPerformed: [BurlyRoutineLastPerformedDTO(routineID: UUID(), performedAt: Fixture.epoch)]
        )
    }

    private func loggedSession(at hours: Int, _ items: [(ExerciseData, [Double])]) -> SessionData {
        let startedAt = Fixture.epoch.addingTimeInterval(Double(hours) * 3_600)
        return SessionData(
            startedAt: startedAt,
            state: .logged,
            origin: .live,
            items: items.enumerated().map { index, entry in
                SessionItemData(
                    exerciseID: entry.0.id,
                    order: index,
                    sets: entry.1.enumerated().map { order, kg in
                        SetRecordData(order: order, weight: Weight(kg: kg), reps: 5, completedAt: startedAt)
                    }
                )
            }
        )
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

    static func seed() throws -> HeavyHistory {
        var rng = SeededGenerator(seed: 0xD1_6E57)
        let store = try makePhoneStore()

        let live = (0..<liveExerciseCount).map {
            Fixture.exercise(name: "Imported \($0)", origin: .hevyImport)
        }
        let archivedUnused = (0..<5).map { Fixture.exercise(name: "Retired \($0)", origin: .hevyImport) }
        let archivedInRoutine = Fixture.exercise(name: "Retired but planned", origin: .hevyImport)
        for exercise in live + archivedUnused + [archivedInRoutine] { try store.createExercise(exercise) }

        // Routine exercises: the first 24, plus the archived one in Legs.
        let routines = (0..<3).map { index in
            Fixture.routine(
                name: ["Push", "Pull", "Legs"][index],
                orderIndex: index,
                over: Array(live[(index * 8)..<(index * 8 + 8)]) + (index == 2 ? [archivedInRoutine] : [])
            )
        }
        for routine in routines { try store.createRoutine(routine) }

        // One session a day. The first 300 days visit every exercise once,
        // in order, so the routine exercises (0..<24) and the extra ones are
        // the oldest; after that only exercises 24..<300 recur, one a day.
        // Days are distinct and each session names an exercise once, so the
        // last session written for an exercise is its latest.
        let extras = [archivedInRoutine] + archivedUnused
        var latest: [UUID: ExerciseLastPerformanceData] = [:]
        for day in 0..<sessionCount {
            let startedAt = Fixture.epoch.addingTimeInterval(Double(day) * 86_400)
            var exercises: [ExerciseData]
            if day < liveExerciseCount {
                exercises = [live[day]]
                if day < extras.count { exercises.append(extras[day]) }
            } else {
                exercises = [live[24 + (day % (liveExerciseCount - 24))]]
            }
            let routine = routines.first { $0.items.contains { $0.exerciseID == exercises[0].id } }
            let items = exercises.enumerated().map { order, exercise in
                SessionItemData(
                    exerciseID: exercise.id,
                    order: order,
                    sets: (0..<Int.random(in: 4...5, using: &rng)).map { setIndex in
                        SetRecordData(
                            order: setIndex,
                            weight: Weight(pounds: Double(Int.random(in: 9...63, using: &rng) * 5)),
                            reps: Int.random(in: 3...12, using: &rng),
                            isWarmup: setIndex == 0,
                            completedAt: startedAt.addingTimeInterval(Double(setIndex) * 150)
                        )
                    }
                )
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
                latest[exerciseID] = ExerciseLastPerformanceData(
                    exerciseID: exerciseID,
                    performedAt: startedAt,
                    sets: item.sets.map { SetSnapshot(weight: $0.weight, reps: $0.reps, isWarmup: $0.isWarmup) }
                )
            }
        }

        let later = Fixture.epoch.addingTimeInterval(Double(sessionCount) * 86_400)
        for exercise in archivedUnused + [archivedInRoutine] {
            try store.archiveExercise(id: exercise.id, at: later)
        }

        let workingSet = Set((live + [archivedInRoutine]).map(\.id))
        return HeavyHistory(
            store: store,
            routineIDs: Set(routines.map(\.id)),
            routineExerciseIDs: Set(routines.flatMap { $0.items.compactMap(\.exerciseID) }),
            archivedUnusedExerciseIDs: Set(archivedUnused.map(\.id)),
            ackedSessionIDs: Set((0..<120).map { _ in UUID() }),
            expectedWorkingSetEntries: latest.values
                .filter { workingSet.contains($0.exerciseID) }
                .sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
        )
    }
}
