// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ConsistencyStats
//
// Spec §7 #4: sessions per week vs. a trailing typical week, plus calendar
// dots. Deliberately no streak counter (spec: "a broken streak punishes
// exactly the person this app is designed for; descriptive beats
// motivational-mechanic").
//
// "Trailing typical week" has no numeric definition in spec §7 — task
// m6-01 interprets it as the mean sessions/week over every *other* week in
// the caller-supplied window (i.e. excluding the current one), so the
// comparison reads as "this week vs. the rest of the window you asked
// for" rather than a second, independently-sized query the caller never
// gets to control. Callers choose how far back "typical" looks by
// choosing what window they fetch (`BurlyStore.loggedSessionDates`).
import Foundation

/// One week's session count.
public struct WeeklySessionCount: Sendable, Equatable {
    public let weekStart: Date
    public let sessionCount: Int
}

public struct ConsistencySummary: Sendable, Equatable {
    /// One entry per week that had >= 1 session, ascending by `weekStart`.
    /// Weeks with zero sessions are not synthesized as zero-count entries —
    /// a caller that wants a dense week axis (e.g. a bar chart with visible
    /// gaps) fills them in from `weekStart`/the reference date it passed.
    /// `trailingTypicalWeekCount` below does NOT derive its denominator
    /// from this array for exactly that reason (see its doc).
    public let weeks: [WeeklySessionCount]
    /// Sessions logged in the calendar week containing the `asOf` date
    /// this summary was computed for.
    public let currentWeekCount: Int
    /// Mean sessions/week over every week in `[since, asOf]` *other* than
    /// the current one — `0` if the window contains no other week. Unlike
    /// `weeks`, this denominator counts a zero-session week as a week
    /// (see the finding this fixes, in `summarize`'s doc).
    public let trailingTypicalWeekCount: Double
    /// One `Date` (calendar-day start) per distinct day that had >= 1
    /// session — "simple calendar dots" (spec §7): presence, not count.
    public let calendarDots: [Date]
}

public enum ConsistencyStats {
    /// - Parameters:
    ///   - sessionDates: `startedAt` for every `.logged` session in the
    ///     `[windowStart, referenceDate]` window
    ///     (`BurlyStore.loggedSessionDates`), any order.
    ///   - windowStart: the lower bound of the window `sessionDates` was
    ///     queried with — i.e. the same `since` passed to
    ///     `loggedSessionDates`. Needed even though every session in
    ///     `sessionDates` already falls at or after it (m6-01 fix round 1,
    ///     major #1): a week in the window that logged *zero* sessions has
    ///     no representation in `sessionDates` at all, so the only way to
    ///     know it belongs in the "typical week" denominator is to know
    ///     where the window itself starts. Before this fix, the
    ///     denominator was derived from `sessionDates` alone, so an
    ///     8-week window with six empty trailing weeks silently averaged
    ///     over the one or two weeks that happened to have a session,
    ///     reporting a wildly inflated "typical week."
    ///   - referenceDate: "now" for the purposes of "current week" — a
    ///     parameter rather than `Date()` so this stays fixture-testable.
    ///   - calendar: the user's calendar (time zone + week-start
    ///     convention) — see `CalendarBucketing`'s doc for why this is
    ///     mandatory rather than a hardcoded UTC epoch week (m6-01 fix
    ///     round 1, major #3).
    public static func summarize(
        sessionDates: [Date],
        since windowStart: Date,
        asOf referenceDate: Date,
        calendar: Calendar
    ) -> ConsistencySummary {
        var perWeek: [Date: Int] = [:]
        var days = Set<Date>()
        for date in sessionDates {
            perWeek[CalendarBucketing.weekStart(for: date, calendar: calendar), default: 0] += 1
            days.insert(CalendarBucketing.dayStart(for: date, calendar: calendar))
        }

        let weeks = perWeek
            .map { WeeklySessionCount(weekStart: $0.key, sessionCount: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }

        let currentWeekStart = CalendarBucketing.weekStart(for: referenceDate, calendar: calendar)
        let currentWeekCount = perWeek[currentWeekStart] ?? 0

        // The denominator walks the window's own week boundaries — not
        // `weeks`, which only carries weeks that had >= 1 session — so a
        // zero-session week counts as a week rather than vanishing.
        let windowWeekStart = CalendarBucketing.weekStart(for: windowStart, calendar: calendar)
        let totalWeeksInWindow = weekCount(from: windowWeekStart, through: currentWeekStart, calendar: calendar)
        let otherWeekCount = totalWeeksInWindow - 1
        let sumOfOtherWeeks = weeks.reduce(0) { partial, week in
            week.weekStart == currentWeekStart ? partial : partial + week.sessionCount
        }
        let trailingTypical = otherWeekCount > 0
            ? Double(sumOfOtherWeeks) / Double(otherWeekCount)
            : 0

        return ConsistencySummary(
            weeks: weeks,
            currentWeekCount: currentWeekCount,
            trailingTypicalWeekCount: trailingTypical,
            calendarDots: days.sorted()
        )
    }

    /// Number of calendar-week buckets from `start` through `end`
    /// inclusive (both already week-start-aligned) — `1` if they're the
    /// same week, and `1` (rather than looping forever or going negative)
    /// if `start` is somehow after `end`. Walks week-by-week using the
    /// calendar's own arithmetic rather than dividing a `TimeInterval` by
    /// 604,800 seconds, because a calendar week is not always exactly
    /// 7×86,400 seconds once DST is involved.
    private static func weekCount(from start: Date, through end: Date, calendar: Calendar) -> Int {
        guard start <= end else { return 1 }
        var count = 1
        var cursor = start
        while cursor < end {
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else { break }
            cursor = next
            count += 1
        }
        return count
    }
}
