// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic watch-store scenarios for BurlyWatchUITests
// (Scripts/acceptance-sim.sh). Debug-only, and driven entirely by an
// XCUITest launch-environment variable -- a real device launch never sets
// it and always falls through to the on-device store (BurlyWatchApp.swift).
//
// BurlySync's snapshot/digest transport (spec §5) is a later milestone, so
// today the ONLY way routines exist in the watch store is this seed. It
// stands in for "a snapshot + digest already arrived from the phone" so the
// routine-list and "Empty session" (§2) states can be exercised on the
// simulator before that transport is built.

import Foundation
import BurlyCore
import BurlyPersistence

#if DEBUG
enum WatchDemoSeed {
    /// Matched literally (not shared code) by BurlyWatchUITests.swift -- the
    /// UI test target runs out-of-process and can only reach this app
    /// through `XCUIApplication.launchEnvironment`.
    static let environmentKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    enum Scenario: String {
        /// Two routines built from the shipped catalog seed (§9); one has a
        /// logged session so its row exercises "last done N days ago," the
        /// other stays "Never done."
        case routines
        /// A guaranteed-empty, isolated store -- the §5 fresh-install case,
        /// independent of whatever the on-device default store holds.
        case empty
    }

    /// `nil` for any launch that isn't one of these scenarios, so the
    /// caller falls through to the real on-device store.
    static func requestedStore() -> BurlyStore? {
        guard
            let raw = ProcessInfo.processInfo.environment[environmentKey],
            let scenario = Scenario(rawValue: raw)
        else {
            return nil
        }
        return try? makeStore(for: scenario)
    }

    private static func makeStore(for scenario: Scenario) throws -> SwiftDataStore {
        let store = try SwiftDataStore(kind: .watch, at: .inMemory)
        if scenario == .routines {
            try seedRoutines(into: store)
        }
        return store
    }

    private static func seedRoutines(into store: SwiftDataStore) throws {
        let seed = try SeedLoader.applyBundled(to: store)
        func exerciseID(named name: String) -> UUID? {
            seed.exercises.first { $0.name == name }?.id
        }

        guard
            let squatID = exerciseID(named: "Back Squat"),
            let benchID = exerciseID(named: "Barbell Bench Press"),
            let pullUpID = exerciseID(named: "Pull-Up")
        else {
            return // Catalog content changed; leave the demo sparse rather than crash.
        }

        let legDay = RoutineData(
            name: "Leg Day",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: squatID, order: 0)],
            updatedAt: .now
        )
        let pushPull = RoutineData(
            name: "Push/Pull",
            orderIndex: 1,
            items: [
                RoutineItemData(exerciseID: benchID, order: 0),
                RoutineItemData(exerciseID: pullUpID, order: 1)
            ],
            updatedAt: .now
        )
        try store.createRoutine(legDay)
        try store.createRoutine(pushPull)

        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now
        try store.createSession(SessionData(
            routineID: legDay.id,
            routineName: legDay.name,
            startedAt: threeDaysAgo,
            endedAt: threeDaysAgo.addingTimeInterval(45 * 60),
            state: .logged,
            origin: .live,
            items: [SessionItemData(exerciseID: squatID, order: 0)]
        ))
    }
}
#endif
