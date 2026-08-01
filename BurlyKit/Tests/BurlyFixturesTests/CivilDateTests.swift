// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("CivilDate and CivilDateTime")
struct CivilDateTests {
    // MARK: - CivilDate

    @Test("day 0 is the 1970-01-01 epoch")
    func epochBoundary() {
        let epoch = CivilDate(dayCount: 0)
        #expect(epoch.year == 1970)
        #expect(epoch.month == 1)
        #expect(epoch.day == 1)
    }

    @Test("day -1 is the day before the epoch")
    func beforeEpoch() {
        let dayBefore = CivilDate(dayCount: -1)
        #expect(dayBefore.year == 1969)
        #expect(dayBefore.month == 12)
        #expect(dayBefore.day == 31)
    }

    @Test("(year, month, day) round-trips through dayCount")
    func yearMonthDayRoundTrips() {
        let date = CivilDate(year: 2025, month: 6, day: 15)
        let reconstructed = CivilDate(dayCount: date.dayCount)
        #expect(reconstructed.year == 2025)
        #expect(reconstructed.month == 6)
        #expect(reconstructed.day == 15)
    }

    @Test("2024-02-29 is a valid leap day; the next day is 2024-03-01")
    func leapYear() {
        let leapDay = CivilDate(year: 2024, month: 2, day: 29)
        let dayAfter = CivilDate(dayCount: leapDay.dayCount + 1)
        #expect(dayAfter.year == 2024)
        #expect(dayAfter.month == 3)
        #expect(dayAfter.day == 1)
    }

    @Test("2023 is not a leap year: the day after Feb 28 is Mar 1")
    func nonLeapYearHasNoFeb29() {
        let feb28 = CivilDate(year: 2023, month: 2, day: 28)
        let dayAfter = CivilDate(dayCount: feb28.dayCount + 1)
        #expect(dayAfter.year == 2023)
        #expect(dayAfter.month == 3)
        #expect(dayAfter.day == 1)
    }

    @Test("CivilDate ordering matches dayCount ordering")
    func ordering() {
        let earlier = CivilDate(year: 2024, month: 1, day: 1)
        let later = CivilDate(year: 2024, month: 12, day: 31)
        #expect(earlier < later)
        #expect(!(later < earlier))
    }

    // MARK: - CivilDateTime normalization / total order

    @Test("minuteOfDay of exactly 1440 rolls forward into dayCount")
    func minuteOverflowRollsForward() {
        let a = CivilDateTime(dayCount: 0, minuteOfDay: 1_440)
        #expect(a.dayCount == 1)
        #expect(a.minuteOfDay == 0)
        #expect(a == CivilDateTime(dayCount: 1, minuteOfDay: 0))
    }

    @Test("negative minuteOfDay rolls back into the previous dayCount")
    func minuteUnderflowRollsBack() {
        let a = CivilDateTime(dayCount: 0, minuteOfDay: -1)
        #expect(a.dayCount == -1)
        #expect(a.minuteOfDay == 1_439)
    }

    @Test("minute overflow spanning multiple days rolls forward correctly")
    func multiDayMinuteOverflow() {
        let a = CivilDateTime(dayCount: 0, minuteOfDay: 1_440 * 3 + 30)
        #expect(a.dayCount == 3)
        #expect(a.minuteOfDay == 30)
    }

    @Test("equal ordinals compare equal: ordering and equality form a total order")
    func totalOrder() {
        let a = CivilDateTime(dayCount: 5, minuteOfDay: 90)
        let b = CivilDateTime(dayCount: 4, minuteOfDay: 90 + 1_440)
        #expect(a == b)
        #expect(!(a < b))
        #expect(!(b < a))
    }

    // MARK: - Formatting

    @Test("formatted output zero-pads month, day, hour, and minute")
    func zeroPaddedFormatting() {
        let dt = CivilDateTime(dayCount: CivilDate(year: 2025, month: 3, day: 5).dayCount, minuteOfDay: 9 * 60 + 5)
        #expect(dt.formatted == "2025-03-05 09:05:00")
    }

    @Test("formatted output pads the epoch date and midnight correctly")
    func epochFormatting() {
        let dt = CivilDateTime(dayCount: 0, minuteOfDay: 0)
        #expect(dt.formatted == "1970-01-01 00:00:00")
    }
}
