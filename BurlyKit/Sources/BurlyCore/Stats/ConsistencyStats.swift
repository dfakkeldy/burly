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
    public let weeks: [WeeklySessionCount]
    /// Sessions logged in the epoch week containing the `asOf` date this
    /// summary was computed for.
    public let currentWeekCount: Int
    /// Mean sessions/week over every week in `weeks` *other* than the
    /// current one — `0` if there is no other week in the data.
    public let trailingTypicalWeekCount: Double
    /// One `Date` (epoch-aligned day start) per distinct day that had >= 1
    /// session — "simple calendar dots" (spec §7): presence, not count.
    public let calendarDots: [Date]
}

public enum ConsistencyStats {
    /// - Parameters:
    ///   - sessionDates: `startedAt` for every `.logged` session in the
    ///     window (`BurlyStore.loggedSessionDates`), any order.
    ///   - referenceDate: "now" for the purposes of "current week" — a
    ///     parameter rather than `Date()` so this stays fixture-testable.
    public static func summarize(sessionDates: [Date], asOf referenceDate: Date) -> ConsistencySummary {
        var perWeek: [Date: Int] = [:]
        var days = Set<Date>()
        for date in sessionDates {
            perWeek[EpochBucketing.bucketStart(for: date, length: EpochBucketing.weekLength), default: 0] += 1
            days.insert(EpochBucketing.bucketStart(for: date, length: EpochBucketing.dayLength))
        }

        let weeks = perWeek
            .map { WeeklySessionCount(weekStart: $0.key, sessionCount: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }

        let currentWeekStart = EpochBucketing.bucketStart(for: referenceDate, length: EpochBucketing.weekLength)
        let currentWeekCount = perWeek[currentWeekStart] ?? 0

        let otherWeeks = weeks.filter { $0.weekStart != currentWeekStart }
        let trailingTypical = otherWeeks.isEmpty
            ? 0
            : Double(otherWeeks.reduce(0) { $0 + $1.sessionCount }) / Double(otherWeeks.count)

        return ConsistencySummary(
            weeks: weeks,
            currentWeekCount: currentWeekCount,
            trailingTypicalWeekCount: trailingTypical,
            calendarDots: days.sorted()
        )
    }
}
