// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1, ExerciseLastPerformance — watch-store-only write gate.
//
// "The model class lives in BurlyPersistence with the rest of the schema,
//  but only the watch ever writes rows: the phone derives digests from full
//  history at push time … and never stores them."
//  (Models/ExerciseLastPerformance.swift)
//
// Before this review round `SwiftDataStore` accepted a `BurlyStoreKind` at
// construction but discarded it, so a phone-kind store could still write a
// digest through `upsertLastPerformance` with nothing to stop it. These
// tests pin the guard: the write succeeds on a watch-kind store and throws
// `.operationRequiresWatchStore` on a phone-kind store, leaving no row
// behind. (Reads stay open to either kind — see `absentRecordsThrowNotFound`
// in StoreAPISurfaceTests — only the write is watch-only.)

import Foundation
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("§1 — ExerciseLastPerformance is a watch-store-only write")
struct StoreKindTests {

    @Test("upsertLastPerformance succeeds on a watch-kind store")
    func digestWriteSucceedsOnWatchStore() throws {
        let store = try makeStore(.watch)
        let exerciseID = UUID()

        try store.upsertLastPerformance(
            ExerciseLastPerformanceData(
                exerciseID: exerciseID,
                performedAt: Fixture.epoch,
                sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
            )
        )

        let digest = try #require(try store.lastPerformance(exerciseID: exerciseID))
        #expect(digest.sets.count == 1)
        #expect(digest.sets[0].weightKg == 60)
    }

    @Test("upsertLastPerformance throws operationRequiresWatchStore on a phone-kind store, and writes nothing")
    func digestWriteThrowsOnPhoneStore() throws {
        let store = try makeStore(.phone)
        let exerciseID = UUID()

        #expect(throws: BurlyStoreError.operationRequiresWatchStore) {
            try store.upsertLastPerformance(
                ExerciseLastPerformanceData(
                    exerciseID: exerciseID,
                    performedAt: Fixture.epoch,
                    sets: [SetSnapshot(weight: Weight(kg: 60), reps: 8)]
                )
            )
        }

        // The rejected write left no row behind — this isn't just a loud
        // failure, the phone store's content stays empty as the spec requires.
        #expect(try store.lastPerformance(exerciseID: exerciseID) == nil)
    }
}
