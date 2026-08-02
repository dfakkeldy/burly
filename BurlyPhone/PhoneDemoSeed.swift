// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic phone-store scenarios for BurlyPhoneUITests. Debug-only,
// and driven entirely by an XCUITest launch-environment variable — a real
// device launch never sets it and always falls through to the on-device
// store (ContentView.resolveStore).
//
// BurlyPhone's UI tests previously leaned on the on-device store's default
// state (m5-01 review finding 6): residue from another acceptance run made
// the empty-state assertions flaky, and nothing proved a populated store
// renders rows. These scenarios stand in for "a store in this exact state"
// so both sides are exercised deterministically. The seed is fail-closed in
// exactly the shape the watch's WatchDemoSeed was fixed to be (m2-01
// review finding 2.1): once a scenario is recognized, seed failures surface
// as errors — never a silent fall-through to the persistent store.

import Foundation
import BurlyCore
import BurlyPersistence

#if DEBUG
enum PhoneDemoSeed {
    /// Matched literally (not shared code) by BurlyPhoneUITests.swift — the
    /// UI test target runs out-of-process and can only reach this app
    /// through `XCUIApplication.launchEnvironment`.
    static let environmentKey = "BURLY_PHONE_UI_TEST_SCENARIO"

    enum Scenario: String {
        /// A guaranteed-empty, isolated store — the fresh-install shell
        /// state, independent of whatever the on-device default store
        /// holds.
        case empty
        /// Routines plus a logged session, so the populated History /
        /// Routines / Stats rows can be asserted for real (m5-01 review
        /// finding 6): an implementation that hardcodes empty states fails
        /// here.
        case populated
        /// Deliberately fails during construction (m5-01 review finding 6,
        /// same role as WatchDemoSeed's `.brokenSeed`). Exists so
        /// BurlyPhoneUITests can drive the fail-closed path end to end: a
        /// recognized scenario whose seed cannot be built must surface as
        /// an error state, not fall through to the on-device store.
        case brokenSeed
    }

    /// Thrown by a recognized scenario's seed construction. Never converted
    /// to `nil` by `requestedStore()` — see its doc.
    enum SeedError: Error, Equatable {
        /// `.brokenSeed` was requested; this scenario exists only to be
        /// unbuildable.
        case intentionallyBroken
        /// The bundled catalog no longer contains an exercise the
        /// `.populated` fixture requires by name. A renamed or removed
        /// catalog exercise is a fixture/catalog contract violation, not
        /// "no routines yet" — it must not render as an ordinary empty
        /// state.
        case catalogMissingExercise(name: String)
    }

    /// Fixed ids for the seeded rows, so BurlyPhoneUITests can assert the
    /// id-keyed row identifiers (m5-01 review finding 8: routine rows are
    /// keyed by `routine.id`, not name) by literal string. The UI test
    /// target cannot share code with the app, so these literals are
    /// duplicated in BurlyPhoneUITests.swift with a pointer back here.
    enum SeededIDs {
        static let legDayRoutine = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000001")!
        static let pushPullRoutine = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000002")!
        static let loggedSession = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000003")!
    }

    /// `nil` for any launch that isn't one of these scenarios, so the
    /// caller falls through to the real on-device store.
    ///
    /// Once a scenario IS recognized, this fails **closed**: seed
    /// construction or seeding errors come back as `.failure`, never as
    /// `nil` (m5-01 review finding 6). The old `try?`-style shape would
    /// turn a broken fixture into "no scenario requested," which the caller
    /// then silently resolved against the real on-device store — exactly
    /// the leak this type exists to prevent.
    static func requestedStore() -> Result<BurlyStore, Error>? {
        guard
            let raw = ProcessInfo.processInfo.environment[environmentKey],
            let scenario = Scenario(rawValue: raw)
        else {
            return nil
        }
        do {
            return .success(try makeStore(for: scenario))
        } catch {
            return .failure(error)
        }
    }

    private static func makeStore(for scenario: Scenario) throws -> SwiftDataStore {
        guard scenario != .brokenSeed else {
            throw SeedError.intentionallyBroken
        }
        let store = try SwiftDataStore(kind: .phone, at: .inMemory)
        if scenario == .populated {
            try seedPopulated(into: store)
        }
        return store
    }

    private static func seedPopulated(into store: SwiftDataStore) throws {
        let seed = try SeedLoader.applyBundled(to: store)
        func exerciseID(named name: String) throws -> UUID {
            guard let id = seed.exercises.first(where: { $0.name == name })?.id else {
                // Catalog content changed: report it rather than leaving the
                // fixture sparse (m5-01 review finding 6) — a silently
                // routine-less store here renders as "No routines yet,"
                // indistinguishable from a genuine empty install.
                throw SeedError.catalogMissingExercise(name: name)
            }
            return id
        }

        let squatID = try exerciseID(named: "Back Squat")
        let benchID = try exerciseID(named: "Barbell Bench Press")
        let pullUpID = try exerciseID(named: "Pull-Up")

        let legDay = RoutineData(
            id: SeededIDs.legDayRoutine,
            name: "Leg Day",
            orderIndex: 0,
            items: [RoutineItemData(exerciseID: squatID, order: 0)],
            updatedAt: .now
        )
        let pushPull = RoutineData(
            id: SeededIDs.pushPullRoutine,
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
            id: SeededIDs.loggedSession,
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
