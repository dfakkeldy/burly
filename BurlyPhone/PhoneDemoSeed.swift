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
        /// `populated` plus one newer watch session that used two unnamed
        /// placeholder exercises (§6 naming queue), for the naming-queue
        /// UI tests. Its own case so the populated fixture other suites
        /// assert exactly (exercise sets, Stats shares) stays unchanged.
        case namingQueue
        /// Deliberately fails during construction (m5-01 review finding 6,
        /// same role as WatchDemoSeed's `.brokenSeed`). Exists so
        /// BurlyPhoneUITests can drive the fail-closed path end to end: a
        /// recognized scenario whose seed cannot be built must surface as
        /// an error state, not fall through to the on-device store.
        case brokenSeed
        /// Twelve weeks of a synthetic push/pull/legs program, for the App
        /// Store screenshots (StoreScreenshotsUITests). Store-quality rather
        /// than assertion-friendly: no unattributed or bodyweight work, and
        /// no debug rows in the session detail (`isStoreScreenshots`).
        case storeScreenshots
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
        static let placeholderSession = UUID(uuidString: "6F4E2C1A-0000-4000-8000-00000000000D")!
        static let firstPlaceholder = UUID(uuidString: "6F4E2C1A-0000-4000-8000-00000000000E")!
        static let secondPlaceholder = UUID(uuidString: "6F4E2C1A-0000-4000-8000-00000000000F")!
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
        if scenario == .populated || scenario == .namingQueue {
            try seedPopulated(into: store)
            if scenario == .namingQueue {
                try seedPlaceholders(into: store)
            }
        } else if scenario == .storeScreenshots {
            try seedStoreScreenshots(into: store)
        } else {
            // The routine-builder's empty scenario still needs the real
            // curated catalog. "Empty" means no user routines or history,
            // not an unrealistically catalog-less install.
            _ = try SeedLoader.applyBundled(to: store)
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

    /// Two placeholders exactly as the watch creates them (SessionMutator:
    /// the shared name, no tags, `needsNaming`), and the session that used
    /// them, a day old so it is History's newest row.
    private static func seedPlaceholders(into store: SwiftDataStore) throws {
        let placeholderIDs = [SeededIDs.firstPlaceholder, SeededIDs.secondPlaceholder]
        for id in placeholderIDs {
            try store.createExercise(ExerciseData(
                id: id,
                name: SessionMutator.placeholderExerciseName,
                muscleGroups: [],
                origin: .custom,
                needsNaming: true
            ))
        }
        let startedAt = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        try store.createSession(SessionData(
            id: SeededIDs.placeholderSession,
            routineName: "Watch Workout",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30 * 60),
            state: .logged,
            origin: .live,
            items: placeholderIDs.enumerated().map { index, id in
                SessionItemData(exerciseID: id, order: index, sets: [
                    SetRecordData(order: 0, weight: Weight(kg: 20), reps: 10, completedAt: startedAt.addingTimeInterval(Double(index + 1) * 120))
                ])
            }
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

// MARK: - App Store screenshots

extension PhoneDemoSeed {
    /// Fixed ids for the rows StoreScreenshotsUITests opens, repeated
    /// literally there (the UI test target cannot import the app).
    enum StoreScreenshotIDs {
        static let pushRoutine = UUID(uuidString: "6F4E2C1A-0000-4000-8000-0000000000A1")!
        static let pullRoutine = UUID(uuidString: "6F4E2C1A-0000-4000-8000-0000000000A2")!
        static let legsRoutine = UUID(uuidString: "6F4E2C1A-0000-4000-8000-0000000000A3")!
        static let newestSession = UUID(uuidString: "6F4E2C1A-0000-4000-8000-0000000000A4")!
    }

    /// The session detail's DEBUG revision and HealthKit rows exist for UI
    /// assertions; a store screenshot must not show them.
    static var isStoreScreenshots: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == Scenario.storeScreenshots.rawValue
    }

    /// One lift of the synthetic program, in pounds because the en-US
    /// screenshots are taken in pounds (whole-pound numbers then render
    /// exactly). `sets` working sets of `reps`, adding `step` every `every`
    /// sessions of its routine: main lifts climb every second week,
    /// accessories every fourth. A session between steps repeats the last
    /// one exactly, which ties rather than beats it, so only about half the
    /// History rows carry a PR badge. Back Squat's 5 x 5 makes it the newest
    /// session's biggest-volume lift, the one Stats opens on.
    private struct StoreLift {
        let name: String
        var sets = 3
        let reps: Int
        let start: Double
        let step: Double
        let every: Int
        let rest: TimeInterval
        var warmup: Double?

        func pounds(inSession index: Int) -> Double {
            start + step * Double((index + 1) / every)
        }
    }

    private struct StoreRoutine {
        let id: UUID
        let name: String
        let lifts: [StoreLift]
    }

    private static let storeProgram = [
        StoreRoutine(id: StoreScreenshotIDs.pushRoutine, name: "Push", lifts: [
            StoreLift(name: "Barbell Bench Press", reps: 5, start: 155, step: 5, every: 2, rest: 120, warmup: 95),
            StoreLift(name: "Barbell Overhead Press", reps: 8, start: 95, step: 5, every: 4, rest: 120),
            StoreLift(name: "Incline Dumbbell Bench Press", reps: 10, start: 50, step: 5, every: 4, rest: 90),
            StoreLift(name: "Dumbbell Lateral Raise", reps: 12, start: 15, step: 2.5, every: 4, rest: 60),
            StoreLift(name: "Cable Triceps Pushdown", reps: 12, start: 50, step: 5, every: 4, rest: 60)
        ]),
        StoreRoutine(id: StoreScreenshotIDs.pullRoutine, name: "Pull", lifts: [
            StoreLift(name: "Conventional Deadlift", reps: 5, start: 245, step: 10, every: 2, rest: 180, warmup: 135),
            StoreLift(name: "Lat Pulldown", reps: 10, start: 120, step: 10, every: 4, rest: 90),
            StoreLift(name: "Seated Cable Row", reps: 10, start: 110, step: 10, every: 4, rest: 90),
            StoreLift(name: "Face Pull", reps: 15, start: 35, step: 5, every: 4, rest: 60),
            StoreLift(name: "Hammer Curl", reps: 10, start: 25, step: 5, every: 4, rest: 60)
        ]),
        StoreRoutine(id: StoreScreenshotIDs.legsRoutine, name: "Legs", lifts: [
            StoreLift(name: "Back Squat", sets: 5, reps: 5, start: 205, step: 10, every: 2, rest: 180, warmup: 135),
            StoreLift(name: "Romanian Deadlift", reps: 8, start: 155, step: 10, every: 4, rest: 120),
            StoreLift(name: "Bulgarian Split Squat", reps: 10, start: 30, step: 5, every: 4, rest: 90),
            StoreLift(name: "Lying Leg Curl", reps: 12, start: 70, step: 5, every: 4, rest: 60),
            StoreLift(name: "Standing Calf Raise", reps: 12, start: 135, step: 10, every: 4, rest: 60)
        ])
    ]

    /// Start times, minutes after midnight, cycled so the History rows read
    /// like a real lifter's evenings, lunches and early mornings.
    private static let storeStartMinutes = [1065, 1090, 380, 1050, 735, 1120, 425]

    private static func seedStoreScreenshots(into store: SwiftDataStore) throws {
        let seed = try SeedLoader.applyBundled(to: store)
        func exerciseID(named name: String) throws -> UUID {
            guard let id = seed.exercises.first(where: { $0.name == name })?.id else {
                throw SeedError.catalogMissingExercise(name: name)
            }
            return id
        }

        var routines: [(data: RoutineData, lifts: [StoreLift], exerciseIDs: [UUID])] = []
        for (index, routine) in storeProgram.enumerated() {
            let exerciseIDs = try routine.lifts.map { try exerciseID(named: $0.name) }
            let data = RoutineData(
                id: routine.id,
                name: routine.name,
                orderIndex: index,
                items: routine.lifts.indices.map { order in
                    RoutineItemData(
                        exerciseID: exerciseIDs[order],
                        order: order,
                        defaultSetCount: routine.lifts[order].sets,
                        restOverride: routine.lifts[order].rest
                    )
                },
                updatedAt: .now
            )
            try store.createRoutine(data)
            routines.append((data: data, lifts: routine.lifts, exerciseIDs: exerciseIDs))
        }

        // Twelve weeks of Push, Pull, Legs in turn, newest first: Legs
        // yesterday, then a session every two or three days back from it.
        let calendar = Calendar.current
        let now = Date.now
        let weeks = 12
        for back in 0..<(weeks * 3) {
            let routine = routines[2 - back % 3]
            let sessionIndex = weeks - 1 - back / 3
            let daysAgo = 1 + back * 7 / 3
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now)
            let startedAt = day.addingTimeInterval(TimeInterval(storeStartMinutes[back % storeStartMinutes.count] * 60))
            var setTime = startedAt.addingTimeInterval(4 * 60)
            func nextSetTime() -> Date {
                setTime = setTime.addingTimeInterval(135)
                return setTime
            }

            let items = routine.lifts.indices.map { order -> SessionItemData in
                let lift = routine.lifts[order]
                var sets: [SetRecordData] = []
                if let warmup = lift.warmup {
                    sets.append(SetRecordData(order: 0, weight: Weight(pounds: warmup), reps: 5, isWarmup: true, completedAt: nextSetTime()))
                }
                let weight = Weight(pounds: lift.pounds(inSession: sessionIndex))
                for _ in 0..<lift.sets {
                    sets.append(SetRecordData(order: sets.count, weight: weight, reps: lift.reps, completedAt: nextSetTime()))
                }
                return SessionItemData(exerciseID: routine.exerciseIDs[order], order: order, sets: sets)
            }
            try store.createSession(SessionData(
                id: back == 0 ? StoreScreenshotIDs.newestSession : UUID(),
                routineID: routine.data.id,
                routineName: routine.data.name,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(TimeInterval((46 + back * 7 % 15) * 60)),
                state: .logged,
                origin: .live,
                items: items
            ))
        }
    }
}
#endif
