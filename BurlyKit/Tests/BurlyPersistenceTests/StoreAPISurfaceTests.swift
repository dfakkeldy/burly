// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #3 (shape) plus the archive semantics §1 and §9 rely on.
//
// Acceptance #3 — "attempting hard-delete of a referenced Exercise is
// impossible via the store API surface (no such method)" — is primarily a
// *compile-time* property: `BurlyStore` declares no delete for exercises, so
// the failing call cannot be written. The tests below cover what a test
// still can cover: that archive is the real path, and that the second lock
// (`.deny` on `Exercise`'s relationships) fires if someone reaches past the
// protocol into the context.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 #3 — archive, never delete; store API surface")
struct StoreAPISurfaceTests {

    @Test("archiving an Exercise keeps it and its history; it just leaves the pickers")
    func archivingExercisePreservesHistory() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 100), reps: 5, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let archivedAt = Fixture.epoch.addingTimeInterval(3600)
        try store.archiveExercise(id: bench.id, at: archivedAt)

        #expect(try store.exercises(includingArchived: false).isEmpty)
        #expect(try store.exercises(includingArchived: true).map(\.id) == [bench.id])
        #expect(try store.exercise(id: bench.id)?.archivedAt == archivedAt)

        // History still resolves to the exercise.
        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].exerciseID == bench.id)
        #expect(stored.items[0].sets.count == 1)
    }

    @Test("archiving a Routine hides it from the list but keeps it fetchable by id")
    func archivingRoutineHidesItFromTheList() throws {
        let store = try makeStore()
        let squat = Fixture.exercise(name: "Squat", muscleGroups: [.quads])
        let routine = Fixture.routine(name: "Legs", over: [squat])
        try store.createExercise(squat)
        try store.createRoutine(routine)

        let archivedAt = Fixture.epoch.addingTimeInterval(60)
        try store.archiveRoutine(id: routine.id, at: archivedAt)

        #expect(try store.routines(includingArchived: false).isEmpty)
        #expect(try store.routines(includingArchived: true).map(\.id) == [routine.id])
        #expect(try store.routine(id: routine.id)?.archivedAt == archivedAt)
        #expect(try store.routine(id: routine.id)?.items.count == 1)
    }

    /// Pins a measured SwiftData behavior, not a Burly design choice.
    ///
    /// `Exercise` declares `.deny` on both inverse relationships, which
    /// *reads* as "a referenced exercise cannot be deleted". SwiftData does
    /// not honour it: the delete saves cleanly and behaves like `.nullify`,
    /// vaporising the exercise and orphaning the history that pointed at it.
    ///
    /// So this test documents the hazard rather than a protection: the
    /// absence of a delete method on `BurlyStore` is the *only* thing
    /// standing between §1's history-integrity rule and data loss. If a
    /// future SwiftData starts enforcing `.deny`, this test fails — update
    /// the comments in Models/Exercise.swift and Store/BurlyStore.swift then.
    @Test("SwiftData does not enforce `.deny` — API absence is the only guard on Exercise deletion")
    func denyRuleIsNotEnforcedBySwiftData() throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let store = SwiftDataStore(container: container)

        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)

        // Reaching past `BurlyStore` — only possible with @testable, and
        // exactly the mistake §1 acceptance #3 forbids by omitting the method.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = bench.id
        var descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let model = try #require(try context.fetch(descriptor).first)
        #expect(!model.routineItems.isEmpty)
        #expect(!model.sessionItems.isEmpty)

        context.delete(model)
        try context.save()

        let verifier = SwiftDataStore(container: container)
        #expect(try verifier.exercise(id: bench.id) == nil)
        #expect(try verifier.session(id: session.id)?.items[0].exerciseID == nil)
        #expect(try verifier.routine(id: routine.id)?.items[0].exerciseID == nil)
    }

    @Test("creates are strict: a duplicate id throws rather than silently upserting")
    func duplicateCreatesThrow() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)

        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)

        #expect(throws: BurlyStoreError.duplicateID(bench.id)) {
            try store.createExercise(Fixture.exercise(id: bench.id, name: "Bench Press (dupe)"))
        }
        #expect(throws: BurlyStoreError.duplicateID(routine.id)) {
            try store.createRoutine(routine)
        }
        #expect(throws: BurlyStoreError.duplicateID(session.id)) {
            try store.createSession(session)
        }
        // The original name survived — no silent overwrite.
        #expect(try store.exercise(id: bench.id)?.name == "Bench Press")
    }

    @Test("a routine or session item naming an unknown exercise is rejected, not stored dangling")
    func danglingExerciseReferencesAreRejected() throws {
        let store = try makeStore()
        let ghostID = UUID()
        let routine = RoutineData(
            name: "Broken",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: ghostID, order: 0)],
            updatedAt: Fixture.epoch
        )

        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.createRoutine(routine)
        }

        let session = SessionData(
            startedAt: Fixture.epoch,
            origin: .live,
            items: [SessionItemData(exerciseID: ghostID, order: 0)]
        )
        #expect(throws: BurlyStoreError.missingExercise(ghostID)) {
            try store.createSession(session)
        }
    }

    @Test("a nil exercise reference is allowed — the spec's relationships are optional")
    func nilExerciseReferenceIsAllowed() throws {
        let store = try makeStore()
        let routine = RoutineData(
            name: "Placeholder day",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: nil, order: 0)],
            updatedAt: Fixture.epoch
        )
        try store.createRoutine(routine)
        #expect(try store.routine(id: routine.id) == routine)
    }

    @Test("mutating an absent record throws notFound instead of failing silently")
    func absentRecordsThrowNotFound() throws {
        let store = try makeStore()
        let ghostID = UUID()

        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.archiveExercise(id: ghostID, at: Fixture.epoch)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.archiveRoutine(id: ghostID, at: Fixture.epoch)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.deleteRoutine(id: ghostID)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.deleteSession(id: ghostID)
        }
        #expect(throws: BurlyStoreError.notFound(ghostID)) {
            try store.logSet(
                SetRecordData(order: 0, weight: .bodyweight, reps: 10, completedAt: Fixture.epoch),
                toSessionItem: ghostID
            )
        }
        #expect(try store.exercise(id: ghostID) == nil)
        #expect(try store.routine(id: ghostID) == nil)
        #expect(try store.session(id: ghostID) == nil)
        #expect(try store.lastPerformance(exerciseID: ghostID) == nil)
    }

    @Test("list fetches use the spec's orderings")
    func listOrderings() throws {
        let store = try makeStore()
        let zercher = Fixture.exercise(name: "Zercher Squat", muscleGroups: [.quads])
        let arnold = Fixture.exercise(name: "Arnold Press", muscleGroups: [.shoulders])
        try store.createExercise(zercher)
        try store.createExercise(arnold)
        // §9: catalog browsing is alphabetical.
        #expect(try store.exercises(includingArchived: false).map(\.name) == ["Arnold Press", "Zercher Squat"])

        let second = Fixture.routine(name: "B", orderIndex: 1, over: [arnold])
        let first = Fixture.routine(name: "A", orderIndex: 0, over: [zercher])
        try store.createRoutine(second)
        try store.createRoutine(first)
        // §9: routines are in the user's manual order.
        #expect(try store.routines(includingArchived: false).map(\.name) == ["A", "B"])

        let older = Fixture.session(from: first, startedAt: Fixture.epoch)
        let newer = Fixture.session(from: first, startedAt: Fixture.epoch.addingTimeInterval(86_400))
        try store.createSession(older)
        try store.createSession(newer)
        // §6: history is reverse-chronological.
        #expect(try store.sessions().map(\.id) == [newer.id, older.id])
    }

    @Test("an already-archived exercise can still be referenced by a brand-new routine — archival hides pickers, it doesn't quarantine the exercise")
    func archivedExerciseCanStillBeReferencedByANewRoutine() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        try store.archiveExercise(id: bench.id, at: Fixture.epoch)

        // A Hevy-import or a routine built from history can still name an
        // archived exercise — history integrity is about the past, and
        // archival only hides the exercise from *pickers* (§1).
        let routine = Fixture.routine(name: "Legacy day", over: [bench])
        try store.createRoutine(routine)
        #expect(try store.routine(id: routine.id)?.items.first?.exerciseID == bench.id)

        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 60), reps: 10, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].exerciseID == bench.id)
        #expect(stored.items[0].sets.count == 1)
        // Still archived, still hidden from the default picker.
        #expect(try store.exercises(includingArchived: false).isEmpty)
    }

    @Test("logSet keeps working on a session item whose exercise is archived mid-session")
    func logSetStillWorksAfterItsExerciseIsArchivedMidSession() throws {
        let store = try makeStore()
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: Weight(kg: 60), reps: 10, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        // Archived between the first and second set — e.g. the phone
        // archived the exercise mid-sync while the watch session runs on.
        try store.archiveExercise(id: bench.id, at: Fixture.epoch.addingTimeInterval(60))

        try store.logSet(
            SetRecordData(order: 1, weight: Weight(kg: 62.5), reps: 8, completedAt: Fixture.epoch.addingTimeInterval(120)),
            toSessionItem: itemID
        )

        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].sets.count == 2)
        #expect(stored.items[0].exerciseID == bench.id)
    }

    /// m1-06 review, finding M5, cold-store read-back probe: `Weight`'s
    /// finite/non-negative invariant is unenforced once a value is a plain
    /// `Double` column on disk, so a corrupted row (out-of-band write, bad
    /// migration, disk corruption) must fail closed on read-back rather
    /// than handing a poisoned `Weight` back into equality/sorting/volume/
    /// PR/chart math. There is no store-API path that can write an invalid
    /// value — every write goes through `Weight`, which now either
    /// validates (Decodable) or traps (programmatic) — so this test reaches
    /// past the store the same way `denyRuleIsNotEnforcedBySwiftData` does,
    /// to simulate the row already being corrupt before the store ever
    /// reads it.
    @Test("a corrupted stored weightKg column fails closed on a genuine cold reload instead of poisoning the returned Weight")
    func corruptedStoredWeightFailsClosedOnColdReload() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)
        let setID = UUID()

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createRoutine(routine)
            try store.createSession(session)
            try store.logSet(
                SetRecordData(id: setID, order: 0, weight: .bodyweight, reps: 5, completedAt: Fixture.epoch),
                toSessionItem: itemID
            )
        }

        // Corrupt the stored column directly — negative, so the thrown
        // error's payload is a normal `Equatable` comparison (unlike NaN,
        // which is never equal to itself).
        do {
            let container = try BurlyContainer.phone(at: .file(url))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var descriptor = FetchDescriptor<SetRecord>(predicate: #Predicate { $0.id == setID })
            descriptor.fetchLimit = 1
            let stored = try #require(try context.fetch(descriptor).first)
            stored.weightKg = -1
            try context.save()
        }

        // Cold reload: brand-new container over the same file.
        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))
        #expect(throws: BurlyStoreError.corruptedWeight(id: setID, underlying: .negative(-1))) {
            try reloaded.session(id: session.id)
        }
        // The whole session fails closed — a caller cannot see the other,
        // uncorrupted sessions' worth of a partially-decoded graph and
        // mistake it for the truth.
        #expect(throws: BurlyStoreError.self) {
            try reloaded.sessions()
        }
    }

    /// Sweeps the hostile-value classes that actually *survive* a genuine
    /// SwiftData round-trip (see `storedNaNHealsToZeroOnColdReload` below
    /// for the one that doesn't) through the same read-back path, using one
    /// shared in-memory container so each case gets a fresh `ModelContext`
    /// fetch (a real read-back through SwiftData's storage layer, not a
    /// cached object) without the cost of a file per case.
    @Test(
        "every weightKg class that survives storage fails closed on read-back, not just negative",
        arguments: [Double.infinity, -.infinity, -1.0]
    )
    func everyInvalidWeightClassFailsClosedOnReadBack(corruptKg: Double) throws {
        let container = try BurlyContainer.phone(at: .inMemory)
        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)
        let setID = UUID()

        let store = SwiftDataStore(container: container)
        try store.createExercise(bench)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(id: setID, order: 0, weight: .bodyweight, reps: 5, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<SetRecord>(predicate: #Predicate { $0.id == setID })
        descriptor.fetchLimit = 1
        let stored = try #require(try context.fetch(descriptor).first)
        stored.weightKg = corruptKg
        try context.save()

        let reloaded = SwiftDataStore(container: container)
        do {
            _ = try reloaded.session(id: session.id)
            Issue.record("expected BurlyStoreError.corruptedWeight for weightKg = \(corruptKg)")
        } catch BurlyStoreError.corruptedWeight(let id, let underlying) {
            #expect(id == setID)
            switch underlying {
            case .negative(let value):
                #expect(value == corruptKg)
            case .notFinite(let value):
                #expect(value.isInfinite == corruptKg.isInfinite)
            }
        }
    }

    /// A stored `NaN` is the one hostile value that never reaches
    /// `SetRecord.snapshot()`'s validation at all: SwiftData's SQLite
    /// backing store cannot represent `NaN` in a `REAL` column, and it
    /// reads back as `0.0` (bodyweight) on a genuine cold reload — verified
    /// here rather than assumed, because it changes what "fails closed"
    /// needs to mean for this specific class. This is not a gap in
    /// `BurlyStoreError.corruptedWeight`: a value that cannot survive
    /// storage as `NaN` cannot poison anything downstream as `NaN` either.
    /// Negative and infinite values *do* survive (see the sweep above) and
    /// are exactly what the validation exists to catch.
    @Test("a stored NaN weightKg heals to 0.0 (bodyweight) on a genuine cold reload, rather than surviving as NaN")
    func storedNaNHealsToZeroOnColdReload() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let routine = Fixture.routine(over: [bench])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)
        let setID = UUID()

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url))
            try store.createExercise(bench)
            try store.createRoutine(routine)
            try store.createSession(session)
            try store.logSet(
                SetRecordData(id: setID, order: 0, weight: .bodyweight, reps: 5, completedAt: Fixture.epoch),
                toSessionItem: itemID
            )
        }

        do {
            let container = try BurlyContainer.phone(at: .file(url))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var descriptor = FetchDescriptor<SetRecord>(predicate: #Predicate { $0.id == setID })
            descriptor.fetchLimit = 1
            let stored = try #require(try context.fetch(descriptor).first)
            stored.weightKg = .nan
            try context.save()
        }

        // Cold reload: brand-new container over the same file.
        let reloaded = try SwiftDataStore(kind: .phone, at: .file(url))
        let stored = try #require(try reloaded.session(id: session.id))
        #expect(stored.items[0].sets[0].weightKg == 0)
    }

    @Test("a 0 kg set is the bodyweight convention, stored and read back as 0")
    func bodyweightIsZeroKilograms() throws {
        let store = try makeStore()
        let pullUp = Fixture.exercise(name: "Pull-up", muscleGroups: [.lats])
        let routine = Fixture.routine(over: [pullUp])
        let session = Fixture.session(from: routine)
        let itemID = try #require(session.items.first?.id)

        try store.createExercise(pullUp)
        try store.createRoutine(routine)
        try store.createSession(session)
        try store.logSet(
            SetRecordData(order: 0, weight: .bodyweight, reps: 12, completedAt: Fixture.epoch),
            toSessionItem: itemID
        )

        let stored = try #require(try store.session(id: session.id))
        #expect(stored.items[0].sets[0].weightKg == 0)
    }
}
