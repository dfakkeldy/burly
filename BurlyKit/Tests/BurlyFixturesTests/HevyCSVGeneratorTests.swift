// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("HevyCSVGenerator")
struct HevyCSVGeneratorTests {
    private static let expectedColumnCount = 8

    private func lines(seed: UInt64 = 21, sessionCount: Int = 10, spanDays: Int = 60) -> [String] {
        let sessions = WorkoutHistoryGenerator.generate(seed: seed, sessionCount: sessionCount, spanDays: spanDays)
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        return csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test("same seed produces byte-identical CSV")
    func determinism() {
        let a = HevyCSVGenerator.generate(sessions: WorkoutHistoryGenerator.generate(seed: 8, sessionCount: 15, spanDays: 90))
        let b = HevyCSVGenerator.generate(sessions: WorkoutHistoryGenerator.generate(seed: 8, sessionCount: 15, spanDays: 90))
        #expect(a == b)
    }

    @Test("header matches the documented column set")
    func header() {
        let rows = lines()
        #expect(rows.first == HevyCSVGenerator.header)
    }

    @Test("every row parses back into the expected column count")
    func columnCount() {
        let rows = lines()
        for row in rows.dropFirst() {
            let columns = row.split(separator: ",", omittingEmptySubsequences: false)
            #expect(columns.count == Self.expectedColumnCount)
        }
    }

    @Test("row count equals total sets across all sessions")
    func rowCountMatchesSetCount() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 4, sessionCount: 12, spanDays: 60)
        let expectedRows = sessions.flatMap(\.exercises).flatMap(\.sets).count
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        let dataRows = csv.split(separator: "\n", omittingEmptySubsequences: true).count - 1
        #expect(dataRows == expectedRows)
    }

    @Test("bodyweight sets render as 0, not 0.0")
    func bodyweightWeightFormatting() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 99, sessionCount: 200, spanDays: 365)
        let csv = HevyCSVGenerator.generate(sessions: sessions)
        #expect(csv.contains(",0,"))
        #expect(!csv.contains(",0.0,"))
    }

    @Test("start_time is never later than end_time on any row")
    func startBeforeEnd() {
        let sessions = WorkoutHistoryGenerator.generate(seed: 17, sessionCount: 20, spanDays: 90)
        for session in sessions {
            #expect(session.start <= session.end)
        }
    }

    @Test("empty session list produces just the header")
    func emptyInput() {
        let csv = HevyCSVGenerator.generate(sessions: [])
        #expect(csv == HevyCSVGenerator.header + "\n")
    }
}
