// SPDX-License-Identifier: GPL-3.0-or-later
//
// Package hevy-pounds: a Hevy account set to pounds writes `weight_lbs` and
// `distance_miles` instead of `weight_kg` and `distance_km`. Before this,
// `weight_kg` was a required column, so every pound user's import aborted as
// "not a Hevy export". These tests pin: either unit's header is accepted,
// exactly one weight column is required, pounds convert to kilograms with
// `Weight.kilogramsPerPound`, miles-only cardio rows are still cardio, the
// unit never changes identity (a pounds and a kilograms export of the same
// workouts dedupe), and the preview equals what the commit writes.
//
// Every CSV is synthetic hand-written text. The pound-unit column names are
// corroborated by third-party Hevy importers, not by a real export (m7-03
// still needs Dan's own file).
import BurlyCore
import Foundation
import Testing
@testable import BurlyImport

@Suite("HevyCSVImporter — pound-unit exports (weight_lbs / distance_miles)")
@MainActor
struct HevyPoundsImportTests {
    private static let poundsHeader =
        "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_lbs,reps,distance_miles,duration_seconds,rpe"
    private static let kilogramsHeader =
        "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe"

    private static func csv(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// One session: warm-up, a 225 lb working set, a bodyweight set, a
    /// miles-only run, a timed plank, and a fractional-pound curl.
    private static func poundsExport(header: String = poundsHeader) -> String {
        csv([
            header,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"warmup",135,10,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",1,"normal",225,5,,,8"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Pull Up",,"",2,"normal",,8,,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Running",,"",3,"normal",,,1.5,900,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Plank (Bodyweight)",,"",4,"normal",,,,60,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bicep Curl (Dumbbell)",,"",5,"normal",22.5,12,,,"#
        ])
    }

    /// The same workout as `poundsExport`, written the way a kilogram
    /// account would write it (weights hand-converted to kg).
    private static let kilogramsExport = csv([
        kilogramsHeader,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"warmup",61.2349,10,,,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",1,"normal",102.0583,5,,,8"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Pull Up",,"",2,"normal",,8,,,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Running",,"",3,"normal",,,2.4,900,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Plank (Bodyweight)",,"",4,"normal",,,,60,"#,
        #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bicep Curl (Dumbbell)",,"",5,"normal",10.2058,12,,,"#
    ])

    private func catalog() throws -> CatalogSeed {
        try CatalogSeed.loadBundled()
    }

    private func parse(_ csv: String) throws -> HevyImportResult {
        try HevyCSVImporter.parse(csv: csv, catalog: try catalog())
    }

    private func allSets(_ result: HevyImportResult) -> [SetRecordData] {
        result.sessions.flatMap(\.items).flatMap(\.sets)
    }

    // MARK: - Header acceptance

    @Test("a weight_lbs / distance_miles header is accepted, with no unknown-column drops")
    func poundsHeaderIsAccepted() throws {
        let result = try parse(Self.poundsExport())

        #expect(result.sessions.count == 1)
        #expect(result.summary.setsImported == 4)
        #expect(result.summary.malformedRowCount == 0)
        // weight_lbs and distance_miles are recognized columns, so their
        // values are never counted as an unknown column's dropped values.
        #expect(result.summary.unknownColumnValuesDropped == 0)
    }

    @Test("the weight_kg / distance_km header is still accepted")
    func kilogramsHeaderStillAccepted() throws {
        let result = try parse(Self.kilogramsExport)

        #expect(result.summary.setsImported == 4)
        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.unknownColumnValuesDropped == 0)
    }

    @Test("header names are matched case-insensitively for the pound columns too")
    func poundsHeaderIsCaseInsensitive() throws {
        let upper = Self.poundsHeader.uppercased()
        let result = try parse(Self.poundsExport(header: upper))

        #expect(result.summary.setsImported == 4)
        #expect(allSets(result).contains { $0.weightKg == Weight(pounds: 225).kg })
    }

    @Test("a header with both weight_kg and weight_lbs is refused with a clear error")
    func bothWeightColumnsAreRefused() throws {
        let both = Self.csv([
            "title,start_time,end_time,exercise_title,set_type,weight_kg,weight_lbs,reps",
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal",100,220,5"#
        ])

        #expect(throws: HevyImportError.ambiguousWeightUnit) {
            _ = try HevyCSVImporter.parse(csv: both, catalog: try catalog())
        }
        let message = try #require(HevyImportError.ambiguousWeightUnit.errorDescription)
        #expect(message.contains("weight_kg") && message.contains("weight_lbs"))
    }

    @Test("a repeated weight column is refused too, so a blank first copy can't import a loaded set as bodyweight")
    func repeatedWeightColumnIsRefused() throws {
        for header in [
            "title,start_time,end_time,exercise_title,set_type,weight_lbs,weight_lbs,reps",
            "title,start_time,end_time,exercise_title,set_type,weight_kg,weight_kg,reps"
        ] {
            let repeated = Self.csv([
                header,
                #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal",,225,5"#
            ])
            #expect(throws: HevyImportError.ambiguousWeightUnit) {
                _ = try HevyCSVImporter.parse(csv: repeated, catalog: try catalog())
            }
        }
    }

    @Test("a header with neither weight column is an unrecognized header naming the either-or requirement")
    func neitherWeightColumnIsRefused() throws {
        let neither = Self.csv([
            "title,start_time,end_time,exercise_title,set_type,reps",
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal",5"#
        ])
        #expect(throws: HevyImportError.unrecognizedHeader(missingColumns: ["weight_kg (or weight_lbs)"])) {
            _ = try HevyCSVImporter.parse(csv: neither, catalog: try catalog())
        }

        let neitherAndNoReps = Self.csv([
            "title,start_time,end_time,exercise_title,set_type",
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal""#
        ])
        #expect(throws: HevyImportError.unrecognizedHeader(missingColumns: ["weight_kg (or weight_lbs)", "reps"])) {
            _ = try HevyCSVImporter.parse(csv: neitherAndNoReps, catalog: try catalog())
        }
    }

    @Test("an empty file names every requirement, in the same order as a header missing them all")
    func emptyFileNamesEveryRequirement() {
        let everyRequirement = ["title", "start_time", "end_time", "exercise_title", "set_type", "weight_kg (or weight_lbs)", "reps"]
        #expect(HevyCSVHeader(fields: []).missingRequiredColumns == everyRequirement)
        #expect(throws: HevyImportError.unrecognizedHeader(missingColumns: everyRequirement)) {
            _ = try HevyCSVImporter.parse(csv: "", catalog: try catalog())
        }
        // A header row of unknown columns lacks the same columns, in the
        // same order.
        #expect(throws: HevyImportError.unrecognizedHeader(missingColumns: everyRequirement)) {
            _ = try HevyCSVImporter.parse(csv: Self.csv(["date,notes"]), catalog: try catalog())
        }
    }

    // MARK: - Conversion precision

    @Test("225 lb converts to the exact kilogram figure Weight(pounds:) produces")
    func twoTwentyFivePoundsConvertsExactly() throws {
        let result = try parse(Self.poundsExport())
        let bench = try #require(result.sessions.first?.items.first?.sets.last)

        #expect(bench.reps == 5)
        #expect(bench.weightKg == Weight(pounds: 225).kg)
        #expect(abs(bench.weightKg - 102.058_283_25) < 1e-9)
        // And it round-trips back to 225 lb for display.
        #expect(abs(Weight(kg: bench.weightKg).pounds - 225) < 1e-9)
    }

    @Test("fractional pounds convert without rounding, and 0 lb stays the bodyweight convention")
    func fractionalAndBodyweightPounds() throws {
        let result = try parse(Self.poundsExport())
        let weights = allSets(result).map(\.weightKg)

        // 135 lb warm-up, 225 lb working set, blank (bodyweight), 22.5 lb curl.
        #expect(weights.count == 4)
        #expect(weights[0] == Weight(pounds: 135).kg)
        #expect(weights[1] == Weight(pounds: 225).kg)
        #expect(weights[2] == 0)
        #expect(weights[3] == Weight(pounds: 22.5).kg)
        #expect(abs(weights[3] - 10.205_828_325) < 1e-9)
    }

    @Test("kilogram files are not scaled")
    func kilogramsAreNotScaled() throws {
        let result = try parse(Self.kilogramsExport)
        let weights = allSets(result).map(\.weightKg)

        #expect(weights == [61.2349, 102.0583, 0, 10.2058])
    }

    @Test("an unusable pound weight is malformed and reports the text as written")
    func invalidPoundWeightIsMalformed() throws {
        func export(weight: String) -> String {
            Self.csv([
                Self.poundsHeader,
                #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"normal",\#(weight),5,,,"#
            ])
        }

        for bad in ["-5", "abc", "NaN", "inf"] {
            let result = try parse(export(weight: bad))
            #expect(result.summary.malformedRowCount == 1, "weight \(bad)")
            #expect(result.summary.setsImported == 0, "weight \(bad)")
            #expect(result.summary.malformedRows.first?.reason == .invalidWeight(bad), "weight \(bad)")
        }
    }

    // MARK: - distance_miles cardio detection

    @Test("a miles-only row is a skipped cardio row, not a malformed strength row")
    func milesOnlyRowIsCardio() throws {
        let csv = Self.csv([
            Self.poundsHeader,
            #""Run","2025-06-16 07:00:00","2025-06-16 07:30:00","","Running",,"",0,"normal",,,3.1,,"#
        ])
        let result = try parse(csv)

        #expect(result.summary.cardioRowsSkipped == 1)
        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.setsImported == 0)
    }

    @Test("a zero distance_miles value with no duration is not cardio")
    func zeroMilesIsNotCardio() throws {
        let csv = Self.csv([
            Self.poundsHeader,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","","Bench Press (Barbell)",,"",0,"normal",135,5,0,,"#
        ])
        let result = try parse(csv)

        #expect(result.summary.cardioRowsSkipped == 0)
        #expect(result.summary.setsImported == 1)
    }

    @Test("a nonempty distance_miles value must be finite and non-negative or the row is malformed")
    func invalidMilesIsMalformed() throws {
        for bad in ["-1", "NaN", "Infinity", "far"] {
            let csv = Self.csv([
                Self.poundsHeader,
                #""Run","2025-06-16 07:00:00","2025-06-16 07:30:00","","Running",,"",0,"normal",,,\#(bad),,"#
            ])
            let result = try parse(csv)

            #expect(result.summary.malformedRowCount == 1, "distance \(bad)")
            #expect(result.summary.cardioRowsSkipped == 0, "distance \(bad)")
            #expect(result.summary.malformedRows.first?.reason == .invalidDistance(bad), "distance \(bad)")
        }
    }

    /// What a row with both distance columns comes to, by its
    /// (distance_km, distance_miles) values.
    enum BothDistancesOutcome: Sendable {
        case cardio
        case imports
        case invalidDistance(String)
    }

    @Test(
        "with both distance columns, each value is checked and either one above zero makes the row cardio",
        arguments: [
            ("0", "2.0", BothDistancesOutcome.cardio),
            ("2.0", "0", BothDistancesOutcome.cardio),
            ("0", "0", BothDistancesOutcome.imports),
            ("far", "2.0", BothDistancesOutcome.invalidDistance("far")),
            ("2.0", "far", BothDistancesOutcome.invalidDistance("far"))
        ] as [(String, String, BothDistancesOutcome)]
    )
    func bothDistanceColumns(kilometers: String, miles: String, outcome: BothDistancesOutcome) throws {
        let csv = Self.csv([
            "title,start_time,end_time,exercise_title,set_type,weight_kg,reps,distance_km,distance_miles",
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal",100,5,\#(kilometers),\#(miles)"#
        ])
        let summary = try parse(csv).summary

        switch outcome {
        case .cardio:
            #expect(summary.cardioRowsSkipped == 1)
            #expect(summary.setsImported == 0)
            #expect(summary.malformedRowCount == 0)
        case .imports:
            #expect(summary.cardioRowsSkipped == 0)
            #expect(summary.setsImported == 1)
            #expect(summary.malformedRowCount == 0)
        case .invalidDistance(let text):
            #expect(summary.cardioRowsSkipped == 0)
            #expect(summary.setsImported == 0)
            #expect(summary.malformedRows.map(\.reason) == [.invalidDistance(text)])
        }
        #expect(summary.unknownColumnValuesDropped == 0)
    }

    @Test(
        "a header mixing units converts weights by the weight column's own unit; the distance column's unit doesn't matter",
        arguments: [
            ("weight_lbs", "distance_km", Weight(pounds: 225).kg),
            ("weight_kg", "distance_miles", 225.0)
        ] as [(String, String, Double)]
    )
    func mixedUnitHeader(weightColumn: String, distanceColumn: String, expectedKg: Double) throws {
        let csv = Self.csv([
            "title,start_time,end_time,exercise_title,set_type,\(weightColumn),reps,\(distanceColumn),duration_seconds",
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Bench Press (Barbell)","normal",225,5,,"#,
            #""Push Day","2025-06-15 08:00:00","2025-06-15 08:45:00","Running","normal",,,3.1,900"#
        ])
        let result = try parse(csv)

        #expect(allSets(result).map(\.weightKg) == [expectedKg])
        #expect(result.summary.cardioRowsSkipped == 1)
        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.unknownColumnValuesDropped == 0)
    }

    @Test("a cardio row in a pound file still has its RPE counted as dropped")
    func milesCardioRowStillAccountsForOtherDrops() throws {
        let csv = Self.csv([
            Self.poundsHeader,
            #""Run","2025-06-16 07:00:00","2025-06-16 07:30:00","","Running","grp-1","note",0,"failure",,,3.1,1800,7"#
        ])
        let result = try parse(csv)

        #expect(result.summary.cardioRowsSkipped == 1)
        #expect(result.summary.rpeValuesDropped == 1)
        #expect(result.summary.supersetRowsDropped == 1)
        #expect(result.summary.exerciseNotesDropped == 1)
        #expect(result.summary.nonStandardSetTypeMarkersFlattened == 1)
    }

    // MARK: - Timed and distance strength rows

    @Test("a timed strength hold counts in the same skipped bucket as cardio, and its neighbours still import")
    func timedHoldIsSkippedNotMalformed() throws {
        let result = try parse(Self.poundsExport())

        // Running (miles + seconds) and Plank (seconds only).
        #expect(result.summary.cardioRowsSkipped == 2)
        #expect(result.summary.malformedRowCount == 0)
        #expect(result.summary.setsImported == 4)
    }

    // MARK: - Identity: the unit never changes an ID

    @Test("a pounds export and a kilograms export of the same workout produce identical IDs")
    func unitDoesNotChangeIdentity() throws {
        let pounds = try parse(Self.poundsExport())
        let kilograms = try parse(Self.kilogramsExport)

        #expect(pounds.sessions.map(\.id) == kilograms.sessions.map(\.id))
        #expect(pounds.sessions.flatMap(\.items).map(\.id) == kilograms.sessions.flatMap(\.items).map(\.id))
        #expect(allSets(pounds).map(\.id) == allSets(kilograms).map(\.id))
        // The weights agree to the precision the kilogram file was written at.
        for (fromPounds, fromKilograms) in zip(allSets(pounds), allSets(kilograms)) {
            #expect(abs(fromPounds.weightKg - fromKilograms.weightKg) < 1e-3)
        }
    }

    @Test("re-importing a pounds export after its import adds nothing")
    func poundsReimportDedupes() throws {
        let first = try HevyImportPlan.make(
            result: try parse(Self.poundsExport()), catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: Set(try catalog().exercises.map(\.id))
        )
        let storedSessionIDs = Set(first.sessionsToCreate.map(\.id))
        let again = try HevyImportPlan.make(
            result: try parse(Self.poundsExport()), catalog: try catalog(),
            existingSessionIDs: storedSessionIDs, existingExerciseIDs: Set(try catalog().exercises.map(\.id))
        )

        #expect(first.preview.newWorkoutCount == 1)
        #expect(again.preview.isNothingNew)
        #expect(again.preview.alreadyImportedWorkoutCount == 1)
    }

    // MARK: - Preview == applied rows

    @Test("the preview of a pounds export equals the rows the commit writes")
    func previewMatchesAppliedRows() throws {
        let result = try parse(Self.poundsExport())
        let plan = try HevyImportPlan.make(
            result: result, catalog: try catalog(),
            existingSessionIDs: [], existingExerciseIDs: Set(try catalog().exercises.map(\.id))
        )
        var writtenSessions: [SessionData] = []
        let outcome = plan.apply(
            createExercise: { _ in },
            createSession: { writtenSessions.append($0) }
        )

        #expect(plan.preview.workoutsInFile == 1)
        #expect(plan.preview.setCount == 4)
        #expect(outcome.matches(plan.preview))
        #expect(outcome.setsCreated == plan.preview.setCount)
        #expect(writtenSessions == plan.sessionsToCreate)
        // What was written carries the converted weights, not the pound text.
        let writtenWeights = writtenSessions.flatMap(\.items).flatMap(\.sets).map(\.weightKg)
        #expect(writtenWeights.contains(Weight(pounds: 225).kg))
        #expect(plan.fileSummary.cardioRowsSkipped == 2)
    }
}
