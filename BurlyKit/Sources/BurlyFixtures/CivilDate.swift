// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// A minimal proleptic-Gregorian calendar date, computed with pure integer
// arithmetic. Deliberately hand-rolled instead of using `Foundation`'s
// `Date`/`Calendar` so this fixture module keeps zero framework imports, as
// required for BurlyCore-adjacent pure-Swift modules. The day-count math is
// Howard Hinnant's well-known `civil_from_days` algorithm (public domain,
// http://howardhinnant.github.io/date_algorithms.html), good for any day
// count representing a real Gregorian calendar date.

/// A calendar date plus a time-of-day, with no timezone concept — fixtures
/// only need a plausible, orderable, human-readable timestamp.
public struct CivilDateTime: Sendable, Comparable {
    public let dayCount: Int
    public let minuteOfDay: Int

    public init(dayCount: Int, minuteOfDay: Int) {
        self.dayCount = dayCount
        self.minuteOfDay = minuteOfDay
    }

    /// Days since 1970-01-01 plus minute-of-day, combined into one
    /// comparable/sortable ordinal so callers can order sessions in time
    /// without formatting them first.
    public var ordinal: Int { dayCount * 1_440 + minuteOfDay }

    public static func < (lhs: CivilDateTime, rhs: CivilDateTime) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    /// (year, month, day) for `dayCount`, where day 0 == 1970-01-01.
    var civilDate: (year: Int, month: Int, day: Int) {
        Self.civilFromDays(dayCount)
    }

    var hour: Int { minuteOfDay / 60 }
    var minute: Int { minuteOfDay % 60 }

    /// Formats as `YYYY-MM-DD HH:MM:SS`, matching the shape of Hevy's
    /// exported timestamps (seconds are always `:00` since fixtures don't
    /// model sub-minute precision).
    public var formatted: String {
        let (y, m, d) = civilDate
        return "\(Self.pad(y, width: 4))-\(Self.pad(m))-\(Self.pad(d)) \(Self.pad(hour)):\(Self.pad(minute)):00"
    }

    private static func pad(_ value: Int, width: Int = 2) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Howard Hinnant's `civil_from_days`, adapted to Swift `Int`.
    private static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        let z2 = z + 719_468
        let era = (z2 >= 0 ? z2 : z2 - 146_096) / 146_097
        let doe = z2 - era * 146_097 // [0, 146096]
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365 // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
        let mp = (5 * doy + 2) / 153 // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1 // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9 // [1, 12]
        return (year: m <= 2 ? y + 1 : y, month: m, day: d)
    }
}
