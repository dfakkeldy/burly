// SPDX-License-Identifier: GPL-3.0-or-later
// m1-04 review — sealing the container boundary.
//
// `ModelContainer` exposes a public `.erase()` (and `.deleteAllData()`): a
// bulk hard-delete that reaches every row in the store in one call, past
// `BurlyStore` entirely. That is the same class of bypass §1 acceptance #3
// already forbids for a single Exercise ("impossible via the store API
// surface") — except unchecked it would apply to the *whole store*, not one
// row. So `BurlyContainer.phone`/`.watch`/`.make` are internal
// (Schema/BurlyContainer.swift), and `SwiftDataStore.init(container:)` is
// internal too: **`ModelContainer` must never appear in a public signature
// of this module.** The public store-construction surface is
// `SwiftDataStore.phone(at:)` / `.watch(at:)` / `.init(kind:at:)`.
//
// This file is the enforcement, in the same spirit as StoreAPISurfaceTests'
// coverage of the missing `deleteExercise`: it is the one file in this test
// target that does **not** `@testable import` BurlyPersistence and does
// **not** `import SwiftData`. Every store here is built and driven through
// the plain public surface, exactly as a real BurlyPhone/BurlyWatch call
// site would. If `BurlyContainer.phone`/`.watch`/`.make` or
// `SwiftDataStore.init(container:)` were ever made `public` again, that is
// a one-line, human-reviewable diff in Schema/BurlyContainer.swift or
// Store/SwiftDataStore.swift — this test does not detect it by failing (a
// wider public surface still compiles), but it does pin the complementary
// fact: the public surface as it stands is sufficient on its own. A
// consumer never needs to reach for `ModelContainer` to get real store work
// done, so there is no functional pressure to widen it.

import Foundation
import Testing
import BurlyCore
import BurlyPersistence

@Suite("m1-04 review — container boundary: no public path yields a ModelContainer")
struct ContainerBoundaryTests {

    @Test("a phone store is constructed and driven entirely through the public surface — no SwiftData import needed")
    func phoneStoreThroughPublicSurfaceOnly() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let bench = ExerciseData(name: "Bench Press", muscleGroups: [.chest, .triceps], origin: .curated)

        try store.createExercise(bench)

        #expect(try store.exercise(id: bench.id) == bench)
        #expect(try store.exercises(includingArchived: false).map(\.id) == [bench.id])
    }

    @Test("a watch store is constructed and driven entirely through the public surface, including the watch-only digest write")
    func watchStoreThroughPublicSurfaceOnly() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        let exerciseID = UUID()

        try store.upsertLastPerformance(
            ExerciseLastPerformanceData(
                exerciseID: exerciseID,
                performedAt: Date(timeIntervalSince1970: 1_780_000_000),
                sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
            )
        )

        let digest = try #require(try store.lastPerformance(exerciseID: exerciseID))
        #expect(digest.sets.count == 1)
        #expect(digest.sets[0].weightKg == 60)
    }

    @Test("the generic init(kind:at:) is also public and needs no SwiftData import either")
    func genericKindInitializerIsAlsoPublic() throws {
        let store = try SwiftDataStore(kind: .phone, at: .inMemory)
        #expect(try store.exercises(includingArchived: true).isEmpty)
    }
}
