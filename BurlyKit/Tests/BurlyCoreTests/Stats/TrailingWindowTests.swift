// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for TrailingWindow (m6-01 fix round 2, review item 7): the
// validated, sentinel-proof domain type that bounds an all-exercises §7
// stats query. These pin its `dateRange(asOf:calendar:)` conversion against
// the same `CalendarBucketing` primitives it is built on, so a future
// refactor of either can't silently drift them apart.
import Testing
import Foundation
@testable import BurlyCore

@Suite("TrailingWindow: validated, sentinel-proof query bound")
struct TrailingWindowTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test(".weeks(_:) converts identically to CalendarBucketing.trailingWeekWindow")
    func weeksMatchesTrailingWeekWindow() {
        let asOf = Date(timeIntervalSince1970: 1_785_672_000)
        let (since, through) = TrailingWindow.weeks(8).dateRange(asOf: asOf, calendar: Self.utc)
        let expected = CalendarBucketing.trailingWeekWindow(weekCount: 8, asOf: asOf, calendar: Self.utc)
        #expect(since == expected.since)
        #expect(through == expected.through)
    }

    @Test(".days(_:) converts identically to CalendarBucketing.trailingDayWindow")
    func daysMatchesTrailingDayWindow() {
        let asOf = Date(timeIntervalSince1970: 1_785_672_000)
        let (since, through) = TrailingWindow.days(30).dateRange(asOf: asOf, calendar: Self.utc)
        let expected = CalendarBucketing.trailingDayWindow(dayCount: 30, asOf: asOf, calendar: Self.utc)
        #expect(since == expected.since)
        #expect(through == expected.through)
    }

    @Test(".weeks(1) is just the current week, matching trailingWeekWindow's own single-week behavior")
    func singleWeek() {
        let asOf = Date(timeIntervalSince1970: 1_785_672_000)
        let (since, through) = TrailingWindow.weeks(1).dateRange(asOf: asOf, calendar: Self.utc)
        #expect(since == CalendarBucketing.weekStart(for: asOf, calendar: Self.utc))
        #expect(through == asOf)
    }

    @Test(".days(1) is just the current day")
    func singleDay() {
        let asOf = Date(timeIntervalSince1970: 1_785_672_000)
        let (since, through) = TrailingWindow.days(1).dateRange(asOf: asOf, calendar: Self.utc)
        #expect(since == CalendarBucketing.dayStart(for: asOf, calendar: Self.utc))
        #expect(through == asOf)
    }

    @Test("two TrailingWindows built the same way are Equatable and equal")
    func equatable() {
        #expect(TrailingWindow.weeks(8) == TrailingWindow.weeks(8))
        #expect(TrailingWindow.days(30) == TrailingWindow.days(30))
        #expect(TrailingWindow.weeks(8) != TrailingWindow.days(56)) // same span, different kind — deliberately not merged
    }
}
