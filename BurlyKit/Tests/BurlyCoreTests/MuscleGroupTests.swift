// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyCore

@Suite("MuscleGroup: frozen 12-value taxonomy")
struct MuscleGroupTests {
    @Test("exactly 12 cases")
    func exactlyTwelveCases() {
        #expect(MuscleGroup.allCases.count == 12)
    }

    @Test("raw values are the frozen, documented lowerCamelCase set (stability snapshot)")
    func rawValueStabilitySnapshot() {
        let expected: Set<String> = [
            "chest", "upperBack", "lats", "shoulders", "biceps", "triceps",
            "forearms", "quads", "hamstrings", "glutes", "calves", "core"
        ]
        let actual = Set(MuscleGroup.allCases.map(\.rawValue))
        #expect(actual == expected)
        // No duplicates snuck in via a rawValue collision.
        #expect(actual.count == MuscleGroup.allCases.count)
    }

    @Test("each frozen rawValue is pinned to its exact case (catches silent renames)")
    func perCaseRawValuePin() {
        #expect(MuscleGroup.chest.rawValue == "chest")
        #expect(MuscleGroup.upperBack.rawValue == "upperBack")
        #expect(MuscleGroup.lats.rawValue == "lats")
        #expect(MuscleGroup.shoulders.rawValue == "shoulders")
        #expect(MuscleGroup.biceps.rawValue == "biceps")
        #expect(MuscleGroup.triceps.rawValue == "triceps")
        #expect(MuscleGroup.forearms.rawValue == "forearms")
        #expect(MuscleGroup.quads.rawValue == "quads")
        #expect(MuscleGroup.hamstrings.rawValue == "hamstrings")
        #expect(MuscleGroup.glutes.rawValue == "glutes")
        #expect(MuscleGroup.calves.rawValue == "calves")
        #expect(MuscleGroup.core.rawValue == "core")
    }

    @Test("multi-tag usage: an exercise can carry more than one MuscleGroup")
    func multiTagUsage() {
        let tags: [MuscleGroup] = [.chest, .triceps, .shoulders]
        #expect(tags.count == 3)
        #expect(Set(tags).count == 3)
    }
}
