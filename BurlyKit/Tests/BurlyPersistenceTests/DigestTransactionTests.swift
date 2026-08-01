// SPDX-License-Identifier: GPL-3.0-or-later
// m1-06 review, M2 — the §5 digest applies as one transaction.
//
// §5's `digest` payload carries two halves of one latest-wins fact: the
// per-exercise last-performance entries the watch's ghost rows render, and
// `ackedSessionIDs` — the sessions the phone has durably received, which the
// watch may therefore prune. Before this round those halves could only be
// applied through separate saves (`upsertLastPerformance` per entry, then
// `pruneDeliveredSessions`), each committing on its own. A crash or a
// throw between them leaves the watch having deleted history it no longer
// holds while its replacement numbers are stale or missing — and because
// application context is latest-wins, there is no redelivery to repair it.
//
// `applyDigest` is the fix: validate the whole payload, then upsert every
// entry and prune every eligible acked session in a single `save()`.

import Foundation
import SwiftData
import Testing
import BurlyCore
import BurlySync
@testable import BurlyPersistence

@Suite("m1-06 M2 — atomic digest application")
struct DigestTransactionTests {

    private func rowCount<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    private func digestEntry(
        for exerciseID: UUID,
        kg: Double,
        reps: Int = 5,
        at date: Date = Fixture.epoch
    ) -> ExerciseLastPerformanceData {
        ExerciseLastPerformanceData(
            exerciseID: exerciseID,
            performedAt: date,
            sets: [SetSnapshot(weight: Weight(kg: kg), reps: reps)]
        )
    }

    /// A watch store holding two exercises, one `.logged` session awaiting
    /// ack, and one `.active` session that must survive everything.
    private func seededWatchStore(
        _ store: SwiftDataStore
    ) throws -> (bench: ExerciseData, row: ExerciseData, logged: SessionData, active: SessionData) {
        let bench = Fixture.exercise(name: "Bench Press")
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        let routine = Fixture.routine(over: [bench, row])
        try store.createExercise(bench)
        try store.createExercise(row)
        try store.createRoutine(routine)

        var logged = Fixture.session(from: routine, startedAt: Fixture.epoch)
        logged.state = .logged
        let active = Fixture.session(from: routine, startedAt: Fixture.epoch.addingTimeInterval(3_600))
        try store.createSession(logged)
        try store.createSession(active)
        return (bench, row, logged, active)
    }

    // MARK: - Both halves, one save

    @Test("entries and the prune land together and survive a cold reopen")
    func entriesAndPruneCommitTogether() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        var benchID = UUID()
        var rowID = UUID()
        var loggedID = UUID()
        var activeID = UUID()

        do {
            let store = try SwiftDataStore(kind: .watch, at: .file(url), clock: TestClock())
            let seeded = try seededWatchStore(store)
            benchID = seeded.bench.id
            rowID = seeded.row.id
            loggedID = seeded.logged.id
            activeID = seeded.active.id

            try store.applyDigest(
                lastPerformance: [
                    digestEntry(for: benchID, kg: 100),
                    digestEntry(for: rowID, kg: 70, reps: 10)
                ],
                ackedSessionIDs: [loggedID]
            )
        }

        let container = try BurlyContainer.make(.watch, at: .file(url))
        let reopened = SwiftDataStore(container: container)

        #expect(try reopened.lastPerformance(exerciseID: benchID)?.sets.first?.weightKg == 100)
        #expect(try reopened.lastPerformance(exerciseID: rowID)?.sets.first?.reps == 10)
        #expect(try reopened.session(id: loggedID) == nil)
        #expect(try reopened.session(id: activeID) != nil)
        #expect(try reopened.loggedSessionsAwaitingAck().isEmpty)
        #expect(try rowCount(Session.self, in: container) == 1)
        #expect(try rowCount(ExerciseLastPerformance.self, in: container) == 2)
    }

    @Test("a later digest overwrites entries latest-wins rather than accumulating rows")
    func laterDigestOverwritesEntries() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)

        try store.applyDigest(
            lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100)],
            ackedSessionIDs: []
        )
        try store.applyDigest(
            lastPerformance: [
                digestEntry(for: seeded.bench.id, kg: 105, reps: 3,
                            at: Fixture.epoch.addingTimeInterval(86_400))
            ],
            ackedSessionIDs: []
        )

        let entry = try #require(try store.lastPerformance(exerciseID: seeded.bench.id))
        #expect(entry.performedAt == Fixture.epoch.addingTimeInterval(86_400))
        #expect(entry.sets.map(\.weightKg) == [105])
        #expect(entry.sets.map(\.reps) == [3])
    }

    // MARK: - Atomicity

    @Test("one invalid entry rejects the WHOLE digest: no entry is upserted and no session is pruned")
    func oneBadEntryRejectsEverything() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)

        // `Weight`'s non-validating initializer is still reachable
        // programmatically (m1-06 review, M5 — owned elsewhere), so a
        // digest assembled from a bad decode can carry this. The digest
        // boundary refuses it rather than poisoning volume/PR maths and the
        // ghost row with a NaN.
        let poisoned = ExerciseLastPerformanceData(
            exerciseID: seeded.row.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: .nan), reps: 5)]
        )

        #expect(throws: BurlyStoreError.invalidLastPerformance(exerciseID: seeded.row.id)) {
            try store.applyDigest(
                lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100), poisoned],
                ackedSessionIDs: [seeded.logged.id]
            )
        }

        // All-or-nothing: the valid entry that came *before* the bad one in
        // the array did not land, and the ack did not prune.
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.lastPerformance(exerciseID: seeded.row.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [seeded.logged.id])
    }

    @Test("a negative weight in a digest entry is refused on the same all-or-nothing terms")
    func negativeWeightRejectsTheDigest() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        let negative = ExerciseLastPerformanceData(
            exerciseID: seeded.bench.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: -20), reps: 5)]
        )

        #expect(throws: BurlyStoreError.invalidLastPerformance(exerciseID: seeded.bench.id)) {
            try store.applyDigest(lastPerformance: [negative], ackedSessionIDs: [seeded.logged.id])
        }
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
    }

    @Test("two entries for the same exercise are ambiguous under latest-wins, so the digest is refused whole")
    func duplicateEntriesRejectTheDigest() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)

        #expect(throws: BurlyStoreError.duplicateID(seeded.bench.id)) {
            try store.applyDigest(
                lastPerformance: [
                    digestEntry(for: seeded.bench.id, kg: 100),
                    digestEntry(for: seeded.bench.id, kg: 110)
                ],
                ackedSessionIDs: [seeded.logged.id]
            )
        }
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
    }

    @Test("a bad digest leaves nothing pending: an unrelated successful save afterwards cannot commit it")
    func rejectedDigestLeavesNoResidue() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        let poisoned = ExerciseLastPerformanceData(
            exerciseID: seeded.row.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: .infinity), reps: 5)]
        )

        #expect(throws: BurlyStoreError.invalidLastPerformance(exerciseID: seeded.row.id)) {
            try store.applyDigest(
                lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100), poisoned],
                ackedSessionIDs: [seeded.logged.id]
            )
        }

        try store.createExercise(Fixture.exercise(name: "Curl", muscleGroups: [.biceps]))

        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.lastPerformance(exerciseID: seeded.row.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
    }

    @Test("upsertLastPerformance applies the same validation as the batch path")
    func singleEntryUpsertValidatesToo() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        let poisoned = ExerciseLastPerformanceData(
            exerciseID: seeded.bench.id,
            performedAt: Fixture.epoch,
            sets: [SetSnapshot(weight: Weight(kg: .nan), reps: 5)]
        )

        #expect(throws: BurlyStoreError.invalidLastPerformance(exerciseID: seeded.bench.id)) {
            try store.upsertLastPerformance(poisoned)
        }
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
    }

    // MARK: - Idempotency

    @Test("replaying the identical digest converges: same entries, same prune result, no throw")
    func replayingADigestConverges() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        let entries = [
            digestEntry(for: seeded.bench.id, kg: 100),
            digestEntry(for: seeded.row.id, kg: 70, reps: 10)
        ]

        try store.applyDigest(lastPerformance: entries, ackedSessionIDs: [seeded.logged.id])
        let afterFirst = try #require(try store.lastPerformance(exerciseID: seeded.bench.id))
        let activeAfterFirst = try #require(try store.session(id: seeded.active.id))

        // A watchOS application-context redelivery: the same payload again.
        // The acked session is already gone, which reads as "unknown id" to
        // the prune — a timing fact, not an error.
        try store.applyDigest(lastPerformance: entries, ackedSessionIDs: [seeded.logged.id])

        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == afterFirst)
        #expect(try store.lastPerformance(exerciseID: seeded.row.id)?.sets.first?.reps == 10)
        #expect(try store.session(id: seeded.logged.id) == nil)
        #expect(try store.session(id: seeded.active.id) == activeAfterFirst)
        #expect(try store.loggedSessionsAwaitingAck().isEmpty)
    }

    @Test("the prune half keeps its documented tolerance: unknown ids and .active sessions are skipped, not treated as errors")
    func pruneToleranceIsUnchanged() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)

        try store.applyDigest(
            lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100)],
            ackedSessionIDs: [UUID(), seeded.active.id, seeded.logged.id, seeded.logged.id]
        )

        #expect(try store.session(id: seeded.logged.id) == nil)
        #expect(try store.session(id: seeded.active.id)?.state == .active)
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id)?.sets.first?.weightKg == 100)
    }

    // MARK: - Gates and the ack seam

    @Test("applyDigest is watch-only and changes nothing on a phone-kind store")
    func applyDigestIsWatchOnly() throws {
        let store = try makeStore(.phone)
        let seeded = try seededWatchStore(store)

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.applyDigest(
                lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100)],
                ackedSessionIDs: [seeded.logged.id]
            )
        }
        #expect(try store.session(id: seeded.logged.id) != nil)
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
    }

    @Test("the BurlySync ack seam now runs through the digest transaction, and still prunes exactly what it did before")
    func ackSeamRoutesThroughApplyDigest() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        // A digest entry already on the watch — the seam must not disturb
        // it while pruning.
        try store.applyDigest(
            lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100)],
            ackedSessionIDs: []
        )

        let sync: SessionAckApplying = store
        try sync.apply(SessionAckReceipt(sessionIDs: [seeded.logged.id, seeded.active.id]))

        #expect(try store.session(id: seeded.logged.id) == nil)
        #expect(try store.session(id: seeded.active.id)?.state == .active)
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id)?.sets.first?.weightKg == 100)
    }

    @Test("the ack seam keeps its phone-kind refusal now that it routes through applyDigest")
    func ackSeamStillRefusesPhoneStores() throws {
        let store = try makeStore(.phone)
        let seeded = try seededWatchStore(store)
        let sync: SessionAckApplying = store

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try sync.apply(SessionAckReceipt(sessionIDs: [seeded.logged.id]))
        }
        #expect(try store.session(id: seeded.logged.id) != nil)
    }

    @Test("an acked session that never retired its journal takes it along, leaving no Resume pointer into a deleted row")
    func pruneRetiresAStrandedJournal() throws {
        let container = try BurlyContainer.make(.watch, at: .inMemory)
        let store = SwiftDataStore(container: container, clock: TestClock())
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        try store.createExercise(bench)
        try store.createRoutine(routine)

        let clock = TestClock()
        var active = SessionBuilder.session(from: routine, clock: clock)
        try store.saveActiveSession(active)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 1)

        // Finish the session *without* going back through the store — the
        // shape a crash between Finish and its save would leave behind.
        try SessionMutator.finish(&active, clock: clock)
        var loggedRow = try #require(try store.session(id: active.id))
        loggedRow.state = .logged
        try store.applyPhoneEdit(loggedRow)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 1)

        try store.applyDigest(lastPerformance: [], ackedSessionIDs: [active.id])

        #expect(try store.session(id: active.id) == nil)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 0)
        #expect(try store.resumableActiveSession() == nil)
    }
}
