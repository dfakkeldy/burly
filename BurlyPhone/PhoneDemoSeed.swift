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
@MainActor
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
        /// The launch-environment key was present but its raw value didn't
        /// match any `Scenario` case — a typo on either side of the
        /// app/test boundary (m5-01 review round 2, finding 2). This is
        /// distinct from the key being absent: an absent key legitimately
        /// falls through to the on-device store, but a present-and-wrong
        /// value must not — the same fail-closed posture as
        /// `.intentionallyBroken` and `.catalogMissingExercise`, just for a
        /// mistake one step earlier.
        case unrecognizedScenario(String)
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
        static let loggedSessionSquatItem = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000004")!
        static let loggedSessionSquatWarmupSet = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000005")!
        static let loggedSessionSquatWorkingSet = UUID(uuidString: "6F4E2C1A-0000-4000-8000-000000000006")!
        static let addableExercise = UUID(uuidString: "6F4E2C1A-0000-4000-8000-00000000000A")!
        static let loggedSessionHealthKitWorkout = UUID(uuidString: "6F4E2C1A-0000-4000-8000-00000000000B")!
    }

    /// `nil` **only** when the launch-environment key is absent entirely,
    /// so the caller falls through to the real on-device store.
    ///
    /// Once the key is present, this fails **closed**, in two separate ways
    /// (m5-01 review round 2, finding 2 — round 1 fixed only the first):
    ///
    /// - the raw value doesn't match any `Scenario` case (a typo) — comes
    ///   back as `.failure(.unrecognizedScenario(raw))`;
    /// - a recognized scenario's seed construction throws (m5-01 review
    ///   finding 6) — comes back as `.failure(error)`.
    ///
    /// The original bug collapsed both of those into the same `nil` the
    /// absent-key case returns, via `guard let raw = ..., let scenario =
    /// Scenario(rawValue: raw) else { return nil }` — a typo'd scenario
    /// name silently fell through to the real on-device store exactly like
    /// the pre-fix `try?` shape did for a broken fixture. Splitting the two
    /// `guard`s is what keeps "the key was set to *something*" from ever
    /// resolving to "the key wasn't set."
    static func requestedStore() -> Result<BurlyStore, Error>? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else {
            return nil
        }
        guard let scenario = Scenario(rawValue: raw) else {
            return .failure(SeedError.unrecognizedScenario(raw))
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
        try store.createExercise(ExerciseData(
            id: SeededIDs.addableExercise,
            name: "UI Test Added Exercise",
            muscleGroups: [],
            origin: .custom
        ))

        // Exercise history spans the longest chart range and deliberately
        // includes recent multi-tag work plus an exercise-less working set.
        // That gives UI tests data for all four charts and verifies the
        // muscle card presents, rather than renormalizes away, unattributed
        // work. The existing literal `loggedSession` remains the most recent
        // row so m5-01's History assertion keeps its stable contract.
        let calendar = Calendar.current
        let weeksAgo = [50, 42, 34, 26, 18, 12, 8, 6, 4, 3, 2, 1]
        for (index, weeks) in weeksAgo.enumerated() {
            let startedAt = calendar.date(byAdding: .weekOfYear, value: -weeks, to: .now) ?? .now
            try store.createSession(makeLoggedSession(
                id: UUID(),
                startedAt: startedAt,
                squatID: squatID,
                benchID: benchID,
                pullUpID: pullUpID,
                routine: legDay,
                progressionIndex: index,
                includesUnattributedWorkingSet: weeks <= 4
            ))
        }

        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: .now) ?? .now
        try store.createSession(makeLoggedSession(
            id: SeededIDs.loggedSession,
            startedAt: threeDaysAgo,
            squatID: squatID,
            benchID: benchID,
            pullUpID: pullUpID,
            routine: legDay,
            progressionIndex: weeksAgo.count,
            includesUnattributedWorkingSet: true
        ))
    }

    private static func makeLoggedSession(
        id: UUID,
        startedAt: Date,
        squatID: UUID,
        benchID: UUID,
        pullUpID: UUID,
        routine: RoutineData,
        progressionIndex: Int,
        includesUnattributedWorkingSet: Bool
    ) -> SessionData {
        let squatWeight = Weight(kg: 60 + Double(progressionIndex) * 2.5)
        let benchWeight = Weight(kg: 40 + Double(progressionIndex) * 1.25)
        let completedAt = startedAt.addingTimeInterval(20 * 60)
        let isAcceptanceSession = id == SeededIDs.loggedSession
        var items = [
            SessionItemData(
                id: isAcceptanceSession ? SeededIDs.loggedSessionSquatItem : UUID(),
                exerciseID: squatID,
                order: 0,
                sets: [
                    SetRecordData(id: isAcceptanceSession ? SeededIDs.loggedSessionSquatWarmupSet : UUID(), order: 0, weight: Weight(kg: 30), reps: 8, isWarmup: true, completedAt: completedAt),
                    SetRecordData(id: isAcceptanceSession ? SeededIDs.loggedSessionSquatWorkingSet : UUID(), order: 1, weight: squatWeight, reps: 5, completedAt: completedAt.addingTimeInterval(90)),
                    SetRecordData(order: 2, weight: squatWeight, reps: 8, completedAt: completedAt.addingTimeInterval(180))
                ]
            ),
            SessionItemData(
                exerciseID: benchID,
                order: 1,
                sets: [
                    SetRecordData(order: 0, weight: benchWeight, reps: 8, completedAt: completedAt.addingTimeInterval(300)),
                    SetRecordData(order: 1, weight: benchWeight, reps: 10, completedAt: completedAt.addingTimeInterval(390))
                ]
            ),
            SessionItemData(
                exerciseID: pullUpID,
                order: 2,
                sets: [
                    SetRecordData(order: 0, weight: .bodyweight, reps: 8, completedAt: completedAt.addingTimeInterval(480))
                ]
            )
        ]
        if includesUnattributedWorkingSet {
            // `SessionItem.exerciseID` is intentionally optional in the
            // persisted model. This is valid logged work but has no muscle
            // tags, so it exercises `unattributedFraction` honestly.
            items.append(SessionItemData(
                exerciseID: nil,
                order: items.count,
                sets: [SetRecordData(order: 0, weight: Weight(kg: 20), reps: 12, completedAt: completedAt.addingTimeInterval(570))]
            ))
        }
        return SessionData(
            id: id,
            routineID: routine.id,
            routineName: routine.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(45 * 60),
            state: .logged,
            healthKitWorkoutID: isAcceptanceSession ? SeededIDs.loggedSessionHealthKitWorkout : nil,
            origin: .live,
            items: items
        )
    }
}
#endif
