// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for ExerciseRecencyStats: which exercise the phone's
// progression chart opens on, and which exercises its picker leads with.
import Testing
import Foundation
@testable import BurlyCore

@Suite("ExerciseRecencyStats: progression default and picker order")
struct ExerciseRecencyStatsTests {
    private static let squat = UUID()
    private static let bench = UUID()
    private static let pullUp = UUID()
    private static let curl = UUID()

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func slice(
        session: UUID,
        startedAt: Date,
        exerciseID: UUID?,
        minutesIn: Double,
        isWarmup: Bool = false
    ) -> SetRecordSlice {
        SetRecordSlice(
            sessionID: session,
            sessionStartedAt: startedAt,
            exerciseID: exerciseID,
            set: SetRecordData(
                order: 0,
                weight: Weight(kg: 60),
                reps: 5,
                isWarmup: isWarmup,
                completedAt: startedAt.addingTimeInterval(minutesIn * 60)
            )
        )
    }

    @Test("Opens on the first working set of the latest session, not its last set")
    func opensOnTheLatestSessionsOpeningLift() {
        let older = UUID()
        let latest = UUID()
        let olderStart = Self.base
        let latestStart = Self.base.addingTimeInterval(3 * 86_400)
        let slices = [
            Self.slice(session: older, startedAt: olderStart, exerciseID: Self.curl, minutesIn: 5),
            // Shuffled on purpose: the store promises no ordering.
            Self.slice(session: latest, startedAt: latestStart, exerciseID: Self.pullUp, minutesIn: 40),
            Self.slice(session: latest, startedAt: latestStart, exerciseID: Self.bench, minutesIn: 20),
            Self.slice(session: latest, startedAt: latestStart, exerciseID: Self.squat, minutesIn: 5),
            Self.slice(session: latest, startedAt: latestStart, exerciseID: nil, minutesIn: 50)
        ]

        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: slices) == Self.squat)
    }

    @Test("Warmups and exercise-less sets never pick the default")
    func warmupsAndUnattributedSetsAreSkipped() {
        let older = UUID()
        let latest = UUID()
        let latestStart = Self.base.addingTimeInterval(86_400)
        let slices = [
            Self.slice(session: older, startedAt: Self.base, exerciseID: Self.bench, minutesIn: 5),
            // The latest session opens with a squat warmup, then its first
            // working set is the curl.
            Self.slice(session: latest, startedAt: latestStart, exerciseID: Self.squat, minutesIn: 1, isWarmup: true),
            Self.slice(session: latest, startedAt: latestStart, exerciseID: nil, minutesIn: 2),
            Self.slice(session: latest, startedAt: latestStart, exerciseID: Self.curl, minutesIn: 10)
        ]
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: slices) == Self.curl)

        // A newer session with only warmups and exercise-less sets doesn't
        // count as training any exercise, so the default stays put.
        let newest = UUID()
        let newestStart = latestStart.addingTimeInterval(86_400)
        let withEmptyNewest = slices + [
            Self.slice(session: newest, startedAt: newestStart, exerciseID: Self.pullUp, minutesIn: 1, isWarmup: true),
            Self.slice(session: newest, startedAt: newestStart, exerciseID: nil, minutesIn: 2)
        ]
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: withEmptyNewest) == Self.curl)
    }

    @Test("Two sessions with the same start time resolve the same way every call")
    func equalStartTimesAreDeterministic() {
        let first = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let slices = [
            Self.slice(session: second, startedAt: Self.base, exerciseID: Self.bench, minutesIn: 5),
            Self.slice(session: first, startedAt: Self.base, exerciseID: Self.squat, minutesIn: 1)
        ]
        // The higher session id wins the tie, whatever the input order.
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: slices) == Self.bench)
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: slices.reversed()) == Self.bench)
    }

    @Test("No working set that names an exercise means no default")
    func emptyAndWarmupOnlyInputHaveNoDefault() {
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: []) == nil)
        let session = UUID()
        let warmupOnly = [
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.squat, minutesIn: 1, isWarmup: true),
            Self.slice(session: session, startedAt: Self.base, exerciseID: nil, minutesIn: 2)
        ]
        #expect(ExerciseRecencyStats.openingExerciseOfLatestSession(from: warmupOnly) == nil)
        #expect(ExerciseRecencyStats.trainedExerciseIDs(from: warmupOnly).isEmpty)
    }

    @Test("Trained exercises are those with a working set; warmup-only ones are not")
    func trainedExerciseIDsCountWorkingSetsOnly() {
        let session = UUID()
        let slices = [
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.squat, minutesIn: 1, isWarmup: true),
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.squat, minutesIn: 5),
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.bench, minutesIn: 10),
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.bench, minutesIn: 12),
            Self.slice(session: session, startedAt: Self.base, exerciseID: Self.curl, minutesIn: 20, isWarmup: true),
            Self.slice(session: session, startedAt: Self.base, exerciseID: nil, minutesIn: 25)
        ]
        #expect(ExerciseRecencyStats.trainedExerciseIDs(from: slices) == [Self.squat, Self.bench])
    }

    @Test("The picker keeps active exercises and only the archived ones trained in the window")
    func pickerHidesArchivedExercisesWithoutRecentHistory() {
        let archivedAt = Self.base
        let exercises = [
            ExerciseData(id: Self.bench, name: "Bench", muscleGroups: [.chest], origin: .curated),
            ExerciseData(id: Self.curl, name: "Curl", muscleGroups: [.biceps], origin: .custom, archivedAt: archivedAt),
            ExerciseData(id: Self.pullUp, name: "Pull-Up", muscleGroups: [.lats], origin: .curated, archivedAt: archivedAt),
            ExerciseData(id: Self.squat, name: "Squat", muscleGroups: [.quads], origin: .curated)
        ]

        let picker = ExerciseRecencyStats.pickerExercises(exercises, trainedIDs: [Self.pullUp, Self.squat])

        // Active exercises stay whether or not they were trained, in the
        // given order; archived Pull-Up stays only because it was trained.
        #expect(picker.map(\.id) == [Self.bench, Self.pullUp, Self.squat])
        #expect(ExerciseRecencyStats.pickerExercises(exercises, trainedIDs: []).map(\.id) == [Self.bench, Self.squat])
    }
}
