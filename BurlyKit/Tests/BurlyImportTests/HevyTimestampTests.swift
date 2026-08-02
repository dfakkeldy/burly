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

    @Test("finding 6.3 — rejects a shape whose digit widths don't match the documented grammar, even though the numbers would otherwise parse")
    func rejectsNonStandardDigitWidths() {
        // Pinning regression: `Int.init` happily parses "6", "5", "8", "3",
        // "0" regardless of width, so the old parser silently accepted
        // this as if it were "2025-06-05 08:03:00".
        #expect(HevyTimestamp.parse("2025-6-5 8:3:0") == nil)
        #expect(HevyTimestamp.parse("25-06-05 08:03:00") == nil) // 2-digit year
        #expect(HevyTimestamp.parse("2025-06-05 08:3:00") == nil) // 1-digit minute
        #expect(HevyTimestamp.parse("2 Jan 2025, 6:05") == nil) // 1-digit hour in the real-export shape
    }

    @Test("round-2 follow-up to finding 6.3 — rejects an internal double space in the real-export shape, even though the tokens themselves are otherwise valid")
    func rejectsInternalDoubleSpace() {
        // Pinning regression: `split(separator: " ",
        // omittingEmptySubsequences: true)` silently absorbed a doubled
        // space between tokens, so "2  Jan 2025, 08:00" parsed
        // successfully despite not matching the documented exact
        // single-space `d MMM yyyy, HH:mm` grammar.
        #expect(HevyTimestamp.parse("2  Jan 2025, 08:00") == nil)
        #expect(HevyTimestamp.parse("2 Jan  2025, 08:00") == nil)
        // A single space between every token is still accepted.
        #expect(HevyTimestamp.parse("2 Jan 2025, 08:00") != nil)
    }

    @Test("finding 2.2 — canonicalKey produces the same value for both formats' representation of the same instant")
    func canonicalKeyMatchesAcrossFormats() throws {
        let a = try #require(HevyTimestamp.parse("2025-12-22 08:00:00"))
        let b = try #require(HevyTimestamp.parse("22 Dec 2025, 08:00"))
        #expect(HevyTimestamp.canonicalKey(for: a) == HevyTimestamp.canonicalKey(for: b))
    }

    @Test("finding 6.1 — an explicit non-UTC timezone shifts the parsed instant relative to the UTC default")
    func explicitTimeZoneShiftsInstant() throws {
        let utc = try #require(HevyTimestamp.parse("2025-06-15 08:00:00", timeZone: HevyTimestamp.defaultTimeZone))
        let fourHoursBehindUTC = try #require(TimeZone(secondsFromGMT: -4 * 3600))
        let shifted = try #require(HevyTimestamp.parse("2025-06-15 08:00:00", timeZone: fourHoursBehindUTC))
        // Pinning regression: the old `parse` had no timezone parameter at
        // all and always assumed UTC, so this would previously equal `utc`
        // regardless of which timezone was intended.
        #expect(shifted == utc.addingTimeInterval(4 * 3600))
    }
}
