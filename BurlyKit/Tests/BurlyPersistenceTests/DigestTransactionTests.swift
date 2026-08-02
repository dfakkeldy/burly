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
//
// Round D finished the job at the *surface* (see BurlyStore.swift): the two
// half-payload methods are module-internal, and BurlySync's receipt cannot
// be built without both halves — so "apply the whole digest" is not merely
// the recommended call, it is the only one a caller outside this module
// has. The seam tests at the bottom drive that shape.

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

        let logged = Fixture.session(from: routine, startedAt: Fixture.epoch)
        try store.createSession(logged)
        let active = Fixture.activeSession(
            from: routine, startedAt: Fixture.epoch.addingTimeInterval(3_600)
        )
        try store.saveActiveSession(active)
        return (bench, row, logged, active.session)
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

    // m1-06 review, fix round B: this suite used to inject the "bad entry"
    // below via `SetSnapshot(weight: Weight(kg: .nan/.infinity/-20), ...)`.
    // That construction is no longer possible to write — `Weight`'s own
    // non-throwing initializers now trap on a non-finite or negative value
    // (finding M5), and `SetSnapshot`'s custom `Decodable` already throws
    // before producing one from a hostile payload. There is no longer any
    // way for an in-memory `[SetSnapshot]` to carry an invalid `weightKg`,
    // so `BurlyStoreError.invalidLastPerformance` and the store-side check
    // that threw it were removed as dead code (see `validateLastPerformance`
    // in SwiftDataStore.swift) rather than kept as an untestable no-op.
    // `Weight`'s unrepresentability of invalid values is pinned by
    // BurlyCoreTests/WeightTests.swift and DomainDecodingTests.swift
    // instead. The atomicity property these tests exist to pin — one bad
    // entry rejects the *whole* digest, including a valid entry that came
    // before it, with no residue for a later save to commit — is still
    // real and still worth pinning, so the tests below now trigger it with
    // the one entry-level failure that remains reachable: two entries
    // claiming latest-wins for the same exercise (`.duplicateID`).

    @Test("one bad entry rejects the WHOLE digest: no entry is upserted and no session is pruned")
    func oneBadEntryRejectsEverything() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)

        // The ambiguous pair (two `row` entries) is what fails; `bench` is
        // an entirely valid entry ahead of it in the array. All-or-nothing
        // means `bench` must not land either.
        #expect(throws: BurlyStoreError.duplicateID(seeded.row.id)) {
            try store.applyDigest(
                lastPerformance: [
                    digestEntry(for: seeded.bench.id, kg: 100),
                    digestEntry(for: seeded.row.id, kg: 70),
                    digestEntry(for: seeded.row.id, kg: 75)
                ],
                ackedSessionIDs: [seeded.logged.id]
            )
        }

        // All-or-nothing: the valid entry that came *before* the bad pair
        // in the array did not land, and the ack did not prune.
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.lastPerformance(exerciseID: seeded.row.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [seeded.logged.id])
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

        #expect(throws: BurlyStoreError.duplicateID(seeded.row.id)) {
            try store.applyDigest(
                lastPerformance: [
                    digestEntry(for: seeded.bench.id, kg: 100),
                    digestEntry(for: seeded.row.id, kg: 70),
                    digestEntry(for: seeded.row.id, kg: 75)
                ],
                ackedSessionIDs: [seeded.logged.id]
            )
        }

        try store.createExercise(Fixture.exercise(name: "Curl", muscleGroups: [.biceps]))

        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.lastPerformance(exerciseID: seeded.row.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
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

    @Test("the BurlySync digest seam runs through the digest transaction, applying its entries and its prune together")
    func digestSeamRoutesThroughApplyDigest() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        // A digest entry already on the watch — the seam must not disturb
        // it while pruning.
        try store.applyDigest(
            lastPerformance: [digestEntry(for: seeded.bench.id, kg: 100)],
            ackedSessionIDs: []
        )

        let sync: SessionDigestApplying = store
        try sync.apply(
            SessionDigestReceipt(
                lastPerformance: [digestEntry(for: seeded.row.id, kg: 70, reps: 10)],
                ackedSessionIDs: [seeded.logged.id, seeded.active.id]
            )
        )

        #expect(try store.session(id: seeded.logged.id) == nil)
        #expect(try store.session(id: seeded.active.id)?.state == .active)
        #expect(try store.lastPerformance(exerciseID: seeded.bench.id)?.sets.first?.weightKg == 100)
        // The receipt's own entry landed in the same call that pruned —
        // the half the ids-only seam could not carry (m1-06 review round D).
        #expect(try store.lastPerformance(exerciseID: seeded.row.id)?.sets.first?.reps == 10)
    }

    @Test("a receipt carrying a bad entry commits neither half: the digest is refused and the acked session survives")
    func digestSeamRefusesAPartialPayloadWhole() throws {
        let store = try makeStore(.watch)
        let seeded = try seededWatchStore(store)
        let sync: SessionDigestApplying = store

        // Two entries claiming latest-wins for one exercise: ambiguous, so
        // the whole payload is refused — including the prune it carried.
        // Routing an ack through the seam cannot smuggle it past the
        // entry-level validation.
        #expect(throws: BurlyStoreError.duplicateID(seeded.bench.id)) {
            try sync.apply(
                SessionDigestReceipt(
                    lastPerformance: [
                        digestEntry(for: seeded.bench.id, kg: 100),
                        digestEntry(for: seeded.bench.id, kg: 110)
                    ],
                    ackedSessionIDs: [seeded.logged.id]
                )
            )
        }

        #expect(try store.lastPerformance(exerciseID: seeded.bench.id) == nil)
        #expect(try store.session(id: seeded.logged.id) != nil)
        #expect(try store.loggedSessionsAwaitingAck().map(\.id) == [seeded.logged.id])
    }

    @Test("the digest seam keeps its phone-kind refusal now that it routes through applyDigest")
    func digestSeamStillRefusesPhoneStores() throws {
        let store = try makeStore(.phone)
        let seeded = try seededWatchStore(store)
        let sync: SessionDigestApplying = store

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try sync.apply(
                SessionDigestReceipt(lastPerformance: [], ackedSessionIDs: [seeded.logged.id])
            )
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

        let active = Fixture.activeSession(from: routine)
        try store.saveActiveSession(active)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 1)

        // Strand the journal the way only something outside the store can
        // now: flip the row to `.logged` behind the store's back. Every
        // in-API path out of `.active` retires the journal in the same save
        // (m1-06 review round D), so this state is no longer reachable
        // through `applyPhoneEdit` — but a crash mid-migration or an
        // out-of-band writer could still produce it, and the prune's
        // defensive cleanup is what keeps it from becoming a Resume pointer
        // into a deleted row.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sessionID = active.id
        var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionID })
        descriptor.fetchLimit = 1
        let row = try #require(try context.fetch(descriptor).first)
        row.state = .logged
        try context.save()
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 1)

        let pruner = SwiftDataStore(container: container, clock: TestClock())
        try pruner.applyDigest(lastPerformance: [], ackedSessionIDs: [active.id])

        #expect(try pruner.session(id: active.id) == nil)
        #expect(try rowCount(ActiveSessionJournal.self, in: container) == 0)
        #expect(try pruner.resumableActiveSession() == nil)
    }
}
