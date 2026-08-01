// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("HevyCSVGenerator")
struct HevyCSVGeneratorTests {
    private static let expectedColumnCount = 8
    private static let referenceStartDate = CivilDate(year: 2025, month: 6, day: 15)

    private func lines(seed: UInt64 = 21, sessionCount: Int = 10, spanDays: Int = 60) -> [String] {
        let sessions = WorkoutHistoryGenerator.generate(
            seed: seed, sessionCount: sessionCount, spanDays: spanDays, startDate: Self.referenceStartDate
        )
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        return csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Minimal RFC-4180-ish CSV line parser: splits on `,` outside of
    /// double-quoted fields, honoring `""` as an escaped literal quote
    /// inside a quoted field. Deliberately not a naive `split(separator:
    /// ",")`, which breaks on any field that legitimately contains a comma.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
            } else if c == "\"" {
                inQuotes = true
                i += 1
            } else if c == "," {
                fields.append(field)
                field = ""
                i += 1
            } else {
                field.append(c)
                i += 1
            }
        }
        fields.append(field)
        return fields
    }

    /// Parses a `YYYY-MM-DD HH:MM:SS` timestamp into a mixed-radix integer
    /// that sorts chronologically, so `startBeforeEnd` genuinely parses the
    /// generated CSV text rather than re-checking the in-memory model.
    private func parseTimestampOrdinal(_ text: String) -> Int {
        let parts = text.split(separator: " ")
        let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        let (year, month, day) = (dateParts[0], dateParts[1], dateParts[2])
        let (hour, minute, second) = (timeParts[0], timeParts[1], timeParts[2])
        return ((((year * 12 + (month - 1)) * 31 + (day - 1)) * 24 + hour) * 60 + minute) * 60 + second
    }

    @Test("same seed produces byte-identical CSV")
    func determinism() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 8, sessionCount: 15, spanDays: 90, startDate: Self.referenceStartDate)
        let a = HevyCSVGenerator.generate(sessions: sessions)
        let b = HevyCSVGenerator.generate(sessions: sessions)
        #expect(a == b)
    }

    @Test("header matches the literal documented column set")
    func header() {
        let rows = lines()
        #expect(rows.first == "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps")
    }

    @Test("every row parses back into the expected column count via a quote-aware parser")
    func columnCount() {
        let rows = lines()
        for row in rows.dropFirst() {
            let columns = parseCSVLine(row)
            #expect(columns.count == Self.expectedColumnCount)
        }
    }

    @Test("row count equals total sets across all sessions")
    func rowCountMatchesSetCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 4, sessionCount: 12, spanDays: 60, startDate: Self.referenceStartDate)
        let expectedRows = sessions.flatMap(\.exercises).flatMap(\.sets).count
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        let dataRows = csv.split(separator: "\n", omittingEmptySubsequences: true).count - 1
        #expect(dataRows == expectedRows)
    }

    @Test("bodyweight sets render as 0, not 0.0")
    func bodyweightWeightFormatting() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 99, sessionCount: 200, spanDays: 365, startDate: Self.referenceStartDate)
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        #expect(csv.contains(",0,"))
        #expect(!csv.contains(",0.0,"))
    }

    @Test("start_time parsed from the CSV is never later than end_time parsed from the CSV")
    func startBeforeEnd() {
        let rows = lines(seed: 17, sessionCount: 20, spanDays: 90)
        for row in rows.dropFirst() {
            let columns = parseCSVLine(row)
            let start = parseTimestampOrdinal(columns[1])
            let end = parseTimestampOrdinal(columns[2])
            #expect(start <= end)
        }
    }

    @Test("empty session list produces just the header")
    func emptyInput() {
        let csv = HevyCSVGenerator.generate(sessions: [])
        #expect(csv == HevyCSVGenerator.header + "\n")
    }

    @Test("recent sessions render plausible modern years, not the 1970 epoch")
    func epochBugRegression() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 3, sessionCount: 30, spanDays: 90, startDate: Self.referenceStartDate)
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        #expect(!csv.contains("1969-"))
        #expect(!csv.contains("1970-"))
        #expect(csv.contains("2025-"))
    }

    @Test("comma-containing session/exercise titles round-trip through CSV quoting")
    func commaContainingTitleRoundTrips() {
        let session = FixtureSession(
            title: "Leg Day, Heavy",
            start: CivilDateTime(dayCount: Self.referenceStartDate.dayCount, minuteOfDay: 480),
            durationMinutes: 45,
            exercises: [
                FixtureExercise(
                    title: "Squat, Back",
                    muscle: "Quadriceps",
                    sets: [FixtureSet(weightKg: 100, reps: 5)]
                )
            ]
        )

        let csv = HevyCSVGenerator.generate(sessions: [session])
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(rows.count == 2)

        let columns = parseCSVLine(rows[1])
        #expect(columns.count == Self.expectedColumnCount)
        #expect(columns[0] == "Leg Day, Heavy")
        #expect(columns[3] == "Squat, Back")
    }

    @Test("warmup sets render set_type \"warmup\"; working sets render \"normal\"")
    func setTypeReflectsWarmupFlag() {
        let session = FixtureSession(
            title: "Push Day",
            start: CivilDateTime(dayCount: Self.referenceStartDate.dayCount, minuteOfDay: 480),
            durationMinutes: 30,
            exercises: [
                FixtureExercise(
                    title: "Barbell Bench Press",
                    muscle: "Chest",
                    sets: [
                        FixtureSet(weightKg: 40, reps: 8, isWarmup: true),
                        FixtureSet(weightKg: 80, reps: 5)
                    ]
                )
            ]
        )

        let csv = HevyCSVGenerator.generate(sessions: [session])
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let warmupColumns = parseCSVLine(rows[1])
        let workingColumns = parseCSVLine(rows[2])
        #expect(warmupColumns[5] == "warmup")
        #expect(workingColumns[5] == "normal")
    }

    @Test("malformedRowRate of 0 (the default) never corrupts a row")
    func noMalformedRowsByDefault() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 40, sessionCount: 20, spanDays: 60, startDate: Self.referenceStartDate)
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for row in rows.dropFirst() {
            #expect(parseCSVLine(row).count == Self.expectedColumnCount)
        }
    }

    @Test("malformedRowRate of 1 corrupts every data row's column count or weight_kg field")
    func malformedRowRateCorruptsRows() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 40, sessionCount: 20, spanDays: 60, startDate: Self.referenceStartDate)
        let csv = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 1.0, seed: 99)
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for row in rows.dropFirst() {
            let columns = parseCSVLine(row)
            let hasWrongColumnCount = columns.count != Self.expectedColumnCount
            let hasNonNumericWeight = columns.count > 6 && Double(columns[6]) == nil
            #expect(hasWrongColumnCount || hasNonNumericWeight)
        }
    }

    @Test("malformedRowRate is deterministic given the same seed")
    func malformedRowRateIsDeterministic() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 40, sessionCount: 20, spanDays: 60, startDate: Self.referenceStartDate)
        let a = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 0.5, seed: 7)
        let b = HevyCSVGenerator.generate(sessions: sessions, malformedRowRate: 0.5, seed: 7)
        #expect(a == b)
    }
}
