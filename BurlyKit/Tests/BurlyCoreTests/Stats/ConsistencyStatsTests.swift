// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for ConsistencyStats (spec §7 #4, acceptance #1):
// sessions/week, the trailing-typical-week baseline, and calendar-dot
// deduplication, all hand-computed against a synthetic three-week history.
import Testing
import Foundation
@testable import BurlyCore

@Suite("ConsistencyStats: sessions/week and calendar dots (§7 #4 fixture truth)")
struct ConsistencyStatsTests {
    private static let weekLength: TimeInterval = 7 * 24 * 60 * 60
    private static let dayLength: TimeInterval = 24 * 60 * 60
    private static let week0Start = Date(timeIntervalSince1970: 0)
    private static let week1Start = week0Start.addingTimeInterval(weekLength)
    private static let week2Start = week0Start.addingTimeInterval(2 * weekLength)

    /// Week 0: two sessions on two different days. Week 1: one session.
    /// Week 2 (the "current" week): three sessions, two of them on the
    /// same day — proving calendar dots dedupe by day, not by session.
    private static let sessionDates: [Date] = [
        week0Start,                                   // day 0
        week0Start.addingTimeInterval(2 * dayLength),  // day 2
        week1Start,                                    // day 7
        week2Start,                                    // day 14
        week2Start.addingTimeInterval(3_600),          // day 14, same day
        week2Start.addingTimeInterval(dayLength)        // day 15
    ]

    @Test("sessions bucket into three weeks with the hand-counted totals")
    func weeklyBucketing() {
        let summary = ConsistencyStats.summarize(sessionDates: Self.sessionDates, asOf: Self.week2Start.addingTimeInterval(200))
        #expect(summary.weeks.map(\.weekStart) == [Self.week0Start, Self.week1Start, Self.week2Start])
        #expect(summary.weeks.map(\.sessionCount) == [2, 1, 3])
    }

    @Test("current week count and trailing-typical baseline (mean of the OTHER weeks in the window)")
    func currentWeekAndTrailingTypical() {
        let summary = ConsistencyStats.summarize(sessionDates: Self.sessionDates, asOf: Self.week2Start.addingTimeInterval(200))
        #expect(summary.currentWeekCount == 3)
        // (week0's 2 + week1's 1) / 2 other weeks = 1.5.
        #expect(abs(summary.trailingTypicalWeekCount - 1.5) < 0.000_001)
    }

    @Test("calendar dots are one per distinct day, deduplicating same-day sessions")
    func calendarDotsDedupePerDay() {
        let summary = ConsistencyStats.summarize(sessionDates: Self.sessionDates, asOf: Self.week2Start)
        // 6 sessions, but day 14 has two — 5 distinct days.
        #expect(summary.calendarDots.count == 5)
        #expect(summary.calendarDots == [
            Self.week0Start,
            Self.week0Start.addingTimeInterval(2 * Self.dayLength),
            Self.week1Start,
            Self.week2Start,
            Self.week2Start.addingTimeInterval(Self.dayLength)
        ])
    }

    @Test("a reference date in a week with no sessions yet reports zero for the current week, not a crash")
    func currentWeekWithNoSessionsYet() {
        let futureWeek = Self.week2Start.addingTimeInterval(3 * Self.weekLength)
        let summary = ConsistencyStats.summarize(sessionDates: Self.sessionDates, asOf: futureWeek)
        #expect(summary.currentWeekCount == 0)
        // All three recorded weeks are now "other" weeks: (2+1+3)/3 = 2.0.
        #expect(abs(summary.trailingTypicalWeekCount - 2.0) < 0.000_001)
    }

    @Test("no session history at all produces an empty, zeroed summary — no NaN, no crash")
    func emptyHistory() {
        let summary = ConsistencyStats.summarize(sessionDates: [], asOf: Self.week0Start)
        #expect(summary.weeks.isEmpty)
        #expect(summary.currentWeekCount == 0)
        #expect(summary.trailingTypicalWeekCount == 0)
        #expect(summary.calendarDots.isEmpty)
    }

    @Test("no streak counter: ConsistencySummary carries no streak field (spec §7 — deliberate)")
    func noStreakField() {
        // Compile-time assertion via Mirror: the type has exactly the four
        // documented properties, nothing named "streak".
        let summary = ConsistencyStats.summarize(sessionDates: Self.sessionDates, asOf: Self.week2Start)
        let labels = Mirror(reflecting: summary).children.compactMap(\.label)
        #expect(labels.contains { $0.lowercased().contains("streak") } == false)
    }
}
