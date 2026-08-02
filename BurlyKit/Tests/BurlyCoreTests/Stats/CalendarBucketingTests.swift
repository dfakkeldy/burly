// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for CalendarBucketing (m6-01 fix round 1, majors #3 and #5):
// day/week bucketing must honor an explicit Calendar (time zone +
// week-start convention), never a fixed UTC epoch anchor, and a named
// N-week range must align to exactly N week-start buckets.
import Testing
import Foundation
@testable import BurlyCore

@Suite("CalendarBucketing: calendar-aware day/week bucketing")
struct CalendarBucketingTests {
    /// A synthetic, fixed-offset (no DST) UTC-5 zone — fully deterministic
    /// regardless of which date is used, unlike a real IANA zone whose
    /// offset depends on the calendar date.
    private static var utcMinus5: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3_600)!
        return calendar
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Major #3: local time zone, not fixed UTC

    @Test("dayStart uses the calendar's time zone: two instants 2 minutes apart that cross a UTC day do not cross a local one")
    func dayStartUsesLocalTimeZone() {
        // UTC-5 local 23:59 and UTC-5 local 00:01 the next calendar day
        // are two minutes apart in UTC-5 local time but land on the same
        // UTC calendar day only by coincidence of clock arithmetic — pick
        // the inverse instead: local 18:59/19:01, which is UTC 23:59/
        // 00:01 the *next* UTC day (since UTC-5 local 19:00 = UTC
        // midnight). Both are still the same LOCAL calendar day.
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        components.hour = 18
        components.minute = 59
        let before = Self.utcMinus5.date(from: components)!
        components.hour = 19
        components.minute = 1
        let after = Self.utcMinus5.date(from: components)!

        // Sanity: this pair really does cross a UTC calendar day.
        #expect(Self.utc.startOfDay(for: before) != Self.utc.startOfDay(for: after))

        #expect(CalendarBucketing.dayStart(for: before, calendar: Self.utcMinus5) == CalendarBucketing.dayStart(for: after, calendar: Self.utcMinus5))
    }

    @Test("weekStart uses the calendar's time zone: two local instants in the same week can cross the old fixed UTC epoch-week boundary")
    func weekStartUsesLocalTimeZoneNotUTCEpoch() {
        // 1970-01-01T00:00:00Z (the Unix epoch) is a Thursday and was the
        // fixed weekly boundary the old EpochBucketing implementation
        // used unconditionally. In this UTC-5 zone, that instant is
        // 1969-12-31T19:00:00 local — so a session at 18:59 local and one
        // two minutes later at 19:01 local (both the same Wednesday
        // evening, nowhere near a local week boundary under any
        // reasonable first-weekday convention) straddle it.
        var components = DateComponents()
        components.year = 1969
        components.month = 12
        components.day = 31
        components.hour = 18
        components.minute = 59
        let before = Self.utcMinus5.date(from: components)!
        components.hour = 19
        components.minute = 1
        let after = Self.utcMinus5.date(from: components)!

        // Sanity: `after` really is at/past the Unix epoch and `before`
        // is not — i.e. they sit on opposite sides of the old fixed UTC
        // week boundary.
        #expect(before.timeIntervalSince1970 < 0)
        #expect(after.timeIntervalSince1970 >= 0)

        #expect(CalendarBucketing.weekStart(for: before, calendar: Self.utcMinus5) == CalendarBucketing.weekStart(for: after, calendar: Self.utcMinus5))
    }

    @Test("weekStart honors an explicit firstWeekday convention")
    func weekStartHonorsFirstWeekday() {
        var mondayFirst = Self.utc
        mondayFirst.firstWeekday = 2 // Monday
        var sundayFirst = Self.utc
        sundayFirst.firstWeekday = 1 // Sunday

        // A Wednesday, arbitrary: 2026-08-05T12:00:00Z.
        let wednesday = Date(timeIntervalSince1970: 1_785_672_000)

        let mondayWeekStart = CalendarBucketing.weekStart(for: wednesday, calendar: mondayFirst)
        let sundayWeekStart = CalendarBucketing.weekStart(for: wednesday, calendar: sundayFirst)

        // The two conventions must disagree on where the week starts —
        // otherwise this test would not be exercising `firstWeekday` at
        // all — and by less than a full week, since both weeks contain
        // the same reference date.
        #expect(mondayWeekStart != sundayWeekStart)
        #expect(abs(mondayWeekStart.timeIntervalSince(sundayWeekStart)) < 7 * 86_400)
    }

    // MARK: - Major #5: named N-week ranges align to exactly N buckets

    @Test("trailingWeekWindow's since is always aligned to a week start")
    func trailingWeekWindowSinceIsWeekAligned() {
        var calendar = Self.utc
        calendar.firstWeekday = 5 // Thursday, matching the Unix epoch

        // asOf sits mid-week, not on a boundary.
        let asOf = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(8 * 7 * 86_400)
            .addingTimeInterval(3 * 86_400)

        let (since, through) = CalendarBucketing.trailingWeekWindow(weekCount: 8, asOf: asOf, calendar: calendar)

        #expect(since == CalendarBucketing.weekStart(for: since, calendar: calendar))
        #expect(through == asOf)
    }

    @Test("trailingWeekWindow spans exactly weekCount week-start boundaries between since and asOf's own week")
    func trailingWeekWindowSpansExactlyWeekCountBuckets() {
        var calendar = Self.utc
        calendar.firstWeekday = 5

        let asOf = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(8 * 7 * 86_400)
            .addingTimeInterval(3 * 86_400)

        let (since, _) = CalendarBucketing.trailingWeekWindow(weekCount: 8, asOf: asOf, calendar: calendar)

        var boundaries: [Date] = []
        var cursor = since
        let currentWeekStart = CalendarBucketing.weekStart(for: asOf, calendar: calendar)
        while cursor <= currentWeekStart {
            boundaries.append(cursor)
            cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor)!
        }

        #expect(boundaries.count == 8)
        #expect(boundaries.last == currentWeekStart)
    }

    @Test("trailingWeekWindow with weekCount: 1 is just the current week")
    func trailingWeekWindowSingleWeek() {
        let calendar = Self.utc
        let asOf = Date(timeIntervalSince1970: 1_785_672_000)
        let (since, through) = CalendarBucketing.trailingWeekWindow(weekCount: 1, asOf: asOf, calendar: calendar)
        #expect(since == CalendarBucketing.weekStart(for: asOf, calendar: calendar))
        #expect(through == asOf)
    }

    // MARK: - Review round 2, item 5: DST spring-forward is bucketed correctly, not assumed

    /// 2026-03-08 is the US spring-forward Sunday (clocks jump 02:00 local
    /// straight to 03:00, so 02:00-02:59 does not exist that day), and it
    /// is itself a Sunday — a `firstWeekday = 1` (Sunday) calendar's week
    /// boundary lands exactly on it, so the calendar week `[Mar 8, Mar 15)`
    /// contains the transition instead of merely being adjacent to it.
    private static var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1 // Sunday
        return calendar
    }

    @Test("a spring-forward week is 167 hours, not the naive 168 — CalendarBucketing relies on calendar arithmetic, not a fixed 7×86,400s span")
    func springForwardWeekIsOneHourShort() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 8
        let weekStartSunday = Self.newYork.date(from: components)!

        let interval = Self.newYork.dateInterval(of: .weekOfYear, for: weekStartSunday)!
        // A naive fixed 7×86,400-second week would be 604,800 seconds; the
        // real calendar week containing a spring-forward transition is
        // exactly one hour shorter.
        #expect(interval.duration == 167 * 3_600)
        #expect(interval.duration != 168 * 3_600)
    }

    @Test("sessions on either side of the spring-forward gap still bucket into the same calendar day and week (review round 2, item 5 fix)")
    func springForwardTransitionBucketsCorrectlyOnBothSides() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 8

        let weekStartSunday = Self.newYork.date(from: components)!

        // 1:30 AM EST (before the jump) and 3:30 AM EDT (right after —
        // 2:00-2:59 local does not exist that day).
        components.hour = 1
        components.minute = 30
        let beforeJump = Self.newYork.date(from: components)!
        components.hour = 3
        components.minute = 30
        let afterJump = Self.newYork.date(from: components)!

        // Sanity: this pair really does straddle the UTC-offset change —
        // otherwise this fixture would not exercise DST at all.
        #expect(Self.newYork.timeZone.secondsFromGMT(for: beforeJump) != Self.newYork.timeZone.secondsFromGMT(for: afterJump))

        #expect(CalendarBucketing.dayStart(for: beforeJump, calendar: Self.newYork) == CalendarBucketing.dayStart(for: afterJump, calendar: Self.newYork))
        #expect(CalendarBucketing.weekStart(for: beforeJump, calendar: Self.newYork) == weekStartSunday)
        #expect(CalendarBucketing.weekStart(for: afterJump, calendar: Self.newYork) == weekStartSunday)

        // The last moment of the short week and the first moment of the
        // next one must still land in different week buckets — the
        // 167-hour week doesn't bleed into its neighbor.
        components.day = 14
        components.hour = 23
        components.minute = 59
        let lastMomentOfWeek = Self.newYork.date(from: components)!
        components.day = 15
        components.hour = 0
        components.minute = 1
        let firstMomentOfNextWeek = Self.newYork.date(from: components)!

        #expect(CalendarBucketing.weekStart(for: lastMomentOfWeek, calendar: Self.newYork) == weekStartSunday)
        #expect(CalendarBucketing.weekStart(for: firstMomentOfNextWeek, calendar: Self.newYork) != weekStartSunday)
    }
}
