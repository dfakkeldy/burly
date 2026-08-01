// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

@Suite("Codable round-trips for every BurlyCore domain type")
struct DomainCodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("ExerciseData round-trips through JSON")
    func exerciseRoundTrips() throws {
        let value = ExerciseData(
            name: "Bench Press",
            muscleGroups: [.chest, .triceps, .shoulders],
            origin: .curated,
            needsNaming: false,
            archivedAt: nil
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("ExerciseData round-trips a needsNaming placeholder with an archivedAt date")
    func exercisePlaceholderRoundTrips() throws {
        let value = ExerciseData(
            name: "Custom — name on phone",
            muscleGroups: [],
            origin: .custom,
            needsNaming: true,
            archivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("RoutineData round-trips through JSON, including nested items")
    func routineRoundTrips() throws {
        let item = RoutineItemData(exerciseID: UUID(), order: 0, restOverride: 120, note: "warm up first")
        let value = RoutineData(
            name: "Push Day",
            orderIndex: 0,
            items: [item],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("RoutineItemData round-trips through JSON with nil relationship and rest override")
    func routineItemRoundTrips() throws {
        let value = RoutineItemData(exerciseID: nil, order: 2, defaultSetCount: 5, restOverride: nil, note: nil)
        #expect(try roundTrip(value) == value)
    }

    @Test("SessionData round-trips through JSON, including nested items and sets")
    func sessionRoundTrips() throws {
        let set = SetRecordData(
            order: 0,
            weight: Weight(kg: 60),
            reps: 8,
            completedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let item = SessionItemData(exerciseID: UUID(), order: 0, sets: [set])
        let value = SessionData(
            routineID: UUID(),
            routineName: "Push Day",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            state: .logged,
            revision: 2,
            healthKitWorkoutID: UUID(),
            origin: .live,
            items: [item],
            notes: "felt strong"
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("SessionItemData round-trips through JSON")
    func sessionItemRoundTrips() throws {
        let value = SessionItemData(exerciseID: nil, order: 1, sets: [])
        #expect(try roundTrip(value) == value)
    }

    @Test("SetRecordData round-trips through JSON, preserving canonical kg exactly")
    func setRecordRoundTrips() throws {
        let value = SetRecordData(
            order: 0,
            weight: Weight(pounds: 225),
            reps: 5,
            isWarmup: true,
            completedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let decoded = try roundTrip(value)
        #expect(decoded == value)
        #expect(decoded.weightKg == value.weightKg)
    }

    @Test("SetSnapshot round-trips through JSON")
    func setSnapshotRoundTrips() throws {
        let value = SetSnapshot(weight: Weight(kg: 100), reps: 3, isWarmup: false)
        #expect(try roundTrip(value) == value)
    }

    @Test("ExerciseLastPerformanceData round-trips through JSON, including nested SetSnapshots")
    func exerciseLastPerformanceRoundTrips() throws {
        let value = ExerciseLastPerformanceData(
            exerciseID: UUID(),
            performedAt: Date(timeIntervalSince1970: 1_700_000_300),
            sets: [
                SetSnapshot(weight: Weight(kg: 60), reps: 8, isWarmup: true),
                SetSnapshot(weight: Weight(pounds: 225), reps: 5, isWarmup: false)
            ]
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("Weight round-trips through JSON")
    func weightRoundTrips() throws {
        let value = Weight(pounds: 315)
        #expect(try roundTrip(value) == value)
    }

    @Test("MuscleGroup round-trips through JSON as its rawValue string, for every case")
    func muscleGroupRoundTrips() throws {
        for group in MuscleGroup.allCases {
            #expect(try roundTrip(group) == group)
        }
    }

    @Test("ExerciseOrigin round-trips through JSON, for every case")
    func exerciseOriginRoundTrips() throws {
        for origin in ExerciseOrigin.allCases {
            #expect(try roundTrip(origin) == origin)
        }
    }

    @Test("SessionState round-trips through JSON, for every case")
    func sessionStateRoundTrips() throws {
        for state in SessionState.allCases {
            #expect(try roundTrip(state) == state)
        }
    }

    @Test("SessionOrigin round-trips through JSON, for every case")
    func sessionOriginRoundTrips() throws {
        for origin in SessionOrigin.allCases {
            #expect(try roundTrip(origin) == origin)
        }
    }
}
