// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BurlyImport

@Suite("HevyTimestamp")
struct HevyTimestampTests {
    @Test("parses the fixture-generator shape (yyyy-MM-dd HH:mm:ss)")
    func parsesFixtureShape() throws {
        let date = try #require(HevyTimestamp.parse("2025-06-15 08:30:00"))
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components.year == 2025)
        #expect(components.month == 6)
        #expect(components.day == 15)
        #expect(components.hour == 8)
        #expect(components.minute == 30)
        #expect(components.second == 0)
    }

    @Test("parses the real-export shape (d MMM yyyy, HH:mm)")
    func parsesRealExportShape() throws {
        let date = try #require(HevyTimestamp.parse("22 Dec 2025, 08:00"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(components.year == 2025)
        #expect(components.month == 12)
        #expect(components.day == 22)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
    }

    @Test("parses single-digit days and abbreviated months in the real-export shape")
    func parsesSingleDigitDay() throws {
        #expect(HevyTimestamp.parse("2 Jan 2025, 06:05") != nil)
    }

    @Test("rejects an impossible calendar date instead of rolling it forward")
    func rejectsImpossibleDate() {
        #expect(HevyTimestamp.parse("2025-02-30 00:00:00") == nil)
        #expect(HevyTimestamp.parse("31 Feb 2025, 00:00") == nil)
    }

    @Test("rejects an out-of-range month")
    func rejectsOutOfRangeMonth() {
        #expect(HevyTimestamp.parse("2025-13-01 00:00:00") == nil)
    }

    @Test("rejects garbage text")
    func rejectsGarbage() {
        #expect(HevyTimestamp.parse("not a date") == nil)
        #expect(HevyTimestamp.parse("") == nil)
    }

    @Test("rejects a numeric overflow in a date component without crashing")
    func rejectsOverflow() {
        #expect(HevyTimestamp.parse("99999999999999999999-01-01 00:00:00") == nil)
    }

    @Test("month name matching is case-insensitive")
    func monthNameCaseInsensitive() {
        #expect(HevyTimestamp.parse("5 JUN 2025, 10:00") != nil)
        #expect(HevyTimestamp.parse("5 jun 2025, 10:00") != nil)
    }
}
