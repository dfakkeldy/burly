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

    /// Fixed UTC calendar with `firstWeekday = 5` (Thursday). Not an
    /// arbitrary choice: 1970-01-01T00:00:00Z (the Unix epoch, this
    /// fixture's zero point) is itself a Thursday, so a Thursday-start
    /// calendar's week boundaries land exactly on this fixture's existing
    /// `weekN Start` constants — these tests keep their hand-computed
    /// numbers from before the calendar-aware bucketing fix while now
    /// genuinely exercising `CalendarBucketing` through an explicit,
    /// deterministic `Calendar` (m6-01 fix round 1, major #3) rather than
    /// a bucketing primitive that hardcodes UTC/epoch itself.
    private static var utcThursdayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 5
        return calendar
    }

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
        let summary = ConsistencyStats.summarize(
            sessionDates: Self.sessionDates,
            since: Self.week0Start,
            asOf: Self.week2Start.addingTimeInterval(200),
            calendar: Self.utcThursdayCalendar
        )
        #expect(summary.weeks.map(\.weekStart) == [Self.week0Start, Self.week1Start, Self.week2Start])
        #expect(summary.weeks.map(\.sessionCount) == [2, 1, 3])
    }

    @Test("current week count and trailing-typical baseline (mean of the OTHER weeks in the window)")
    func currentWeekAndTrailingTypical() {
        let summary = ConsistencyStats.summarize(
            sessionDates: Self.sessionDates,
            since: Self.week0Start,
            asOf: Self.week2Start.addingTimeInterval(200),
            calendar: Self.utcThursdayCalendar
        )
        #expect(summary.currentWeekCount == 3)
        // (week0's 2 + week1's 1) / 2 other weeks = 1.5.
        #expect(abs(summary.trailingTypicalWeekCount - 1.5) < 0.000_001)
    }

    @Test("calendar dots are one per distinct day, deduplicating same-day sessions")
    func calendarDotsDedupePerDay() {
        let summary = ConsistencyStats.summarize(
            sessionDates: Self.sessionDates,
            since: Self.week0Start,
            asOf: Self.week2Start,
            calendar: Self.utcThursdayCalendar
        )
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
        let summary = ConsistencyStats.summarize(
            sessionDates: Self.sessionDates,
            since: Self.week0Start,
            asOf: futureWeek,
            calendar: Self.utcThursdayCalendar
        )
        #expect(summary.currentWeekCount == 0)
        // The window is now weeks 0 through 5 (6 weeks); the "typical"
        // denominator is the other 5 (weeks 0-4). Weeks 0/1/2 logged
        // 2/1/3 sessions; weeks 3 and 4 logged zero and — after the major
        // #1 fix — still count as weeks in the denominator rather than
        // vanishing: (2+1+3+0+0)/5 = 1.2, not the old (wrong) 2.0 that
        // came from averaging only over the weeks that happened to have a
        // session.
        #expect(abs(summary.trailingTypicalWeekCount - 1.2) < 0.000_001)
    }

    @Test("no session history at all produces an empty, zeroed summary — no NaN, no crash")
    func emptyHistory() {
        let summary = ConsistencyStats.summarize(
            sessionDates: [],
            since: Self.week0Start,
            asOf: Self.week0Start,
            calendar: Self.utcThursdayCalendar
        )
        #expect(summary.weeks.isEmpty)
        #expect(summary.currentWeekCount == 0)
        #expect(summary.trailingTypicalWeekCount == 0)
        #expect(summary.calendarDots.isEmpty)
    }

    @Test("no streak counter: ConsistencySummary carries no streak field (spec §7 — deliberate)")
    func noStreakField() {
        // Compile-time assertion via Mirror: the type has exactly the four
        // documented properties, nothing named "streak".
        let summary = ConsistencyStats.summarize(
            sessionDates: Self.sessionDates,
            since: Self.week0Start,
            asOf: Self.week2Start,
            calendar: Self.utcThursdayCalendar
        )
        let labels = Mirror(reflecting: summary).children.compactMap(\.label)
        #expect(labels.contains { $0.lowercased().contains("streak") } == false)
    }

    // MARK: - Major #1 fix: zero-session weeks belong in the "typical week" denominator

    @Test("an 8-week window with six empty trailing weeks reports 1/7, not the old sparse-weeks average (major #1 fix)")
    func zeroSessionWeeksCountTowardTypicalWeekDenominator() {
        // Exactly the cross-engine review's failing scenario: an 8-week
        // window (weeks 0...7), the current week (7) has 4 sessions, one
        // prior week (1) has a single session, and the other six prior
        // weeks (0, 2, 3, 4, 5, 6) have zero. Before this fix, weeks with
        // no sessions had no entry anywhere the denominator could see, so
        // the "typical week" average silently ran over just the one
        // nonempty prior week — reporting 1.0 instead of the true 1/7.
        func week(_ n: Int) -> Date { Self.week0Start.addingTimeInterval(Double(n) * Self.weekLength) }

        let since = week(0)
        let asOf = week(7).addingTimeInterval(3 * Self.dayLength) // three days into the current (8th) week
        let sessionDates: [Date] = [
            week(1).addingTimeInterval(1_000), // the one prior week with a session
            week(7).addingTimeInterval(1_000),
            week(7).addingTimeInterval(2_000),
            week(7).addingTimeInterval(3_000),
            week(7).addingTimeInterval(4_000)  // current week: 4 sessions
        ]

        let summary = ConsistencyStats.summarize(
            sessionDates: sessionDates,
            since: since,
            asOf: asOf,
            calendar: Self.utcThursdayCalendar
        )

        #expect(summary.currentWeekCount == 4)
        // (1 + 0 + 0 + 0 + 0 + 0 + 0) / 7 other weeks = 0.142857...
        #expect(abs(summary.trailingTypicalWeekCount - (1.0 / 7.0)) < 0.000_001)
    }

    // MARK: - Major #3 fix: local calendar day, not a fixed UTC anchor

    @Test("calendar dots use the caller's local calendar day, not a fixed UTC day boundary (major #3 fix)")
    func calendarDotsRespectLocalTimeZone() {
        // A synthetic, fixed-offset (no DST, fully deterministic) UTC-5
        // zone. Two sessions two minutes apart, both squarely within the
        // same LOCAL calendar day (Dec 31 1969, 18:59 and 19:01 local) —
        // but which cross a UTC calendar-day boundary, since UTC-5 local
        // 19:00 is UTC midnight. Before the fix, bucketing was done on
        // the raw epoch/UTC day, which would have reported these as two
        // separate calendar dots despite being the same evening for the
        // person who logged them.
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(secondsFromGMT: -5 * 3_600)!

        var components = DateComponents()
        components.year = 1969
        components.month = 12
        components.day = 31
        components.hour = 18
        components.minute = 59
        let firstSession = localCalendar.date(from: components)!
        components.hour = 19
        components.minute = 1
        let secondSession = localCalendar.date(from: components)!

        // Sanity check: these two really do cross a UTC calendar day —
        // otherwise this fixture would not exercise the bug at all.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(utcCalendar.startOfDay(for: firstSession) != utcCalendar.startOfDay(for: secondSession))

        let summary = ConsistencyStats.summarize(
            sessionDates: [firstSession, secondSession],
            since: firstSession,
            asOf: secondSession,
            calendar: localCalendar
        )
        #expect(summary.calendarDots.count == 1)
    }
}
