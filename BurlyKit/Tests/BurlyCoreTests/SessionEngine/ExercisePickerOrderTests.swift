// SPDX-License-Identifier: MIT
// Spec §2 mid-session edits: the swap/add picker lists recents, then
// curated, then customs.
import Testing
import Foundation
@testable import BurlyCore

@Suite("§2 Mid-session edits — ExercisePickerOrder")
struct ExercisePickerOrderTests {
    private let squat = ExerciseData(name: "Back Squat", muscleGroups: [.quads], origin: .curated)
    private let bench = ExerciseData(name: "Barbell Bench Press", muscleGroups: [.chest], origin: .curated)
    private let abWheel = ExerciseData(name: "Ab Wheel Rollout", muscleGroups: [.core], origin: .curated)
    private let pullUp = ExerciseData(name: "Pull-Up", muscleGroups: [.lats], origin: .curated)
    private let myCurl = ExerciseData(name: "Cable Curl Variation", muscleGroups: [.biceps], origin: .custom)
    private let imported = ExerciseData(name: "Arnold Press (Hevy)", muscleGroups: [.shoulders], origin: .hevyImport)
    private let placeholder = ExerciseData(
        name: "Custom exercise", muscleGroups: [], origin: .custom, needsNaming: true
    )

    private var catalog: [ExerciseData] {
        [abWheel, imported, squat, bench, myCurl, placeholder, pullUp]
    }

    private func names(_ exercises: [ExerciseData]) -> [String] {
        exercises.map(\.name)
    }

    @Test("with no recents: curated by name, then customs and imports by name; placeholders hidden")
    func noRecentsGroupsCuratedBeforeCustoms() {
        let ordered = ExercisePickerOrder.ordered(catalog, sessionExerciseIDs: [], lastPerformedAt: { _ in nil })

        #expect(names(ordered) == [
            "Ab Wheel Rollout", "Back Squat", "Barbell Bench Press", "Pull-Up",
            "Arnold Press (Hevy)", "Cable Curl Variation"
        ])
    }

    @Test("this session's exercises lead, then digest recents newest first, then the rest")
    func sessionThenDigestRecentsLead() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let performed: [UUID: Date] = [
            myCurl.id: now.addingTimeInterval(-86_400),
            abWheel.id: now.addingTimeInterval(-3 * 86_400),
            squat.id: now.addingTimeInterval(-2 * 86_400)
        ]

        let ordered = ExercisePickerOrder.ordered(
            catalog,
            sessionExerciseIDs: [pullUp.id, squat.id],
            lastPerformedAt: { performed[$0] }
        )

        #expect(names(ordered) == [
            "Pull-Up", "Back Squat",          // in this session, session order
            "Cable Curl Variation",           // digest, newest
            "Ab Wheel Rollout",               // digest, older
            "Barbell Bench Press",            // curated
            "Arnold Press (Hevy)"             // customs and imports
        ])
    }

    @Test("a swap leaves out the exercise it would replace")
    func swapExcludesCurrentExercise() {
        let ordered = ExercisePickerOrder.ordered(
            catalog,
            sessionExerciseIDs: [squat.id],
            lastPerformedAt: { $0 == self.squat.id ? Date() : nil },
            excluding: squat.id
        )

        #expect(!ordered.contains(squat))
        #expect(ordered.first == abWheel)
    }

    @Test("recents are capped; the overflow falls back into its catalog group")
    func recentsAreCapped() {
        let ordered = ExercisePickerOrder.ordered(
            catalog,
            sessionExerciseIDs: [pullUp.id, bench.id, squat.id],
            lastPerformedAt: { _ in nil },
            recentLimit: 2
        )

        #expect(names(ordered) == [
            "Pull-Up", "Barbell Bench Press",
            "Ab Wheel Rollout", "Back Squat",
            "Arnold Press (Hevy)", "Cable Curl Variation"
        ])
    }

    @Test("every listed exercise appears exactly once, and none is invented")
    func noDuplicatesOrStrangers() {
        let stranger = UUID()
        let ordered = ExercisePickerOrder.ordered(
            catalog,
            sessionExerciseIDs: [squat.id, squat.id, stranger, placeholder.id],
            lastPerformedAt: { $0 == self.squat.id ? Date() : nil }
        )

        #expect(Set(ordered.map(\.id)).count == ordered.count)
        #expect(Set(ordered) == Set(catalog.filter { !$0.needsNaming }))
        #expect(ordered.first == squat)
    }
}
