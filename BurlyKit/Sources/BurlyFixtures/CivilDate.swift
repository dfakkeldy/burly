// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// A minimal proleptic-Gregorian calendar date, computed with pure integer
// arithmetic. Deliberately hand-rolled instead of using `Foundation`'s
// `Date`/`Calendar` so this fixture module keeps zero framework imports, as
// required for BurlyCore-adjacent pure-Swift modules. The day-count math is
// Howard Hinnant's well-known `civil_from_days` / `days_from_civil`
// algorithms (public domain,
// http://howardhinnant.github.io/date_algorithms.html), good for any day
// count (or any real Gregorian calendar date) representable as an `Int`.
//
// `CivilDate` and `CivilDateTime` are the *only* date model fixtures use:
// `WorkoutHistoryGenerator` produces `CivilDateTime`s anchored to a
// caller-supplied `CivilDate`, and `HevyCSVGenerator` formats those same
// values — there is no second, silently-different notion of "day 0" hiding
// in either file.

/// A calendar date with no time-of-day or timezone concept: a day count
/// since 1970-01-01, where day 0 is 1970-01-01 itself.
public struct CivilDate: Sendable, Comparable {
    public let dayCount: Int

    public init(dayCount: Int) {
        self.dayCount = dayCount
    }

    /// Constructs from a proleptic-Gregorian `(year, month, day)` triple.
    public init(year: Int, month: Int, day: Int) {
        self.dayCount = Self.daysFromCivil(year: year, month: month, day: day)
    }

    public var year: Int { Self.civilFromDays(dayCount).year }
    public var month: Int { Self.civilFromDays(dayCount).month }
    public var day: Int { Self.civilFromDays(dayCount).day }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        lhs.dayCount < rhs.dayCount
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

    /// Howard Hinnant's `days_from_civil`, the exact inverse of
    /// `civilFromDays` above.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400 // [0, 399]
        let mp = month > 2 ? month - 3 : month + 9 // [0, 11]
        let doy = (153 * mp + 2) / 5 + day - 1 // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}

/// A calendar date plus a time-of-day, with no timezone concept — fixtures
/// only need a plausible, orderable, human-readable timestamp.
public struct CivilDateTime: Sendable, Comparable {
    public let dayCount: Int
    public let minuteOfDay: Int

    /// Normalizes `minuteOfDay` into `[0, 1440)`, rolling any overflow or
    /// underflow into `dayCount`. Without this, two values denoting the same
    /// instant — e.g. `(dayCount: 0, minuteOfDay: 1440)` and
    /// `(dayCount: 1, minuteOfDay: 0)` — would compare unequal under the
    /// synthesized `==` while comparing equal (neither `<` the other) under
    /// `Comparable`'s `ordinal`, breaking the total order. Normalizing here
    /// guarantees a 1:1 mapping between `(dayCount, minuteOfDay)` and
    /// `ordinal`, so `==` and `<` always agree.
    public init(dayCount: Int, minuteOfDay: Int) {
        let (dayDelta, normalizedMinute) = Self.floorDivMod(minuteOfDay, 1_440)
        self.dayCount = dayCount + dayDelta
        self.minuteOfDay = normalizedMinute
    }

    /// Days since 1970-01-01 plus minute-of-day, combined into one
    /// comparable/sortable ordinal so callers can order sessions in time
    /// without formatting them first.
    public var ordinal: Int { dayCount * 1_440 + minuteOfDay }

    public static func < (lhs: CivilDateTime, rhs: CivilDateTime) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    var civilDate: CivilDate { CivilDate(dayCount: dayCount) }

    var hour: Int { minuteOfDay / 60 }
    var minute: Int { minuteOfDay % 60 }

    /// Formats as `YYYY-MM-DD HH:MM:SS`, matching the shape of Hevy's
    /// exported timestamps (seconds are always `:00` since fixtures don't
    /// model sub-minute precision).
    public var formatted: String {
        let date = civilDate
        return "\(Self.pad(date.year, width: 4))-\(Self.pad(date.month))-\(Self.pad(date.day)) \(Self.pad(hour)):\(Self.pad(minute)):00"
    }

    private static func pad(_ value: Int, width: Int = 2) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Floor division and remainder: unlike Swift's `/`/`%` (which truncate
    /// toward zero), this rolls a negative `value` back into the previous
    /// `divisor`-sized bucket instead of leaving a negative remainder.
    private static func floorDivMod(_ value: Int, _ divisor: Int) -> (quotient: Int, remainder: Int) {
        let q = value / divisor
        let r = value % divisor
        if r != 0 && (r < 0) != (divisor < 0) {
            return (q - 1, r + divisor)
        }
        return (q, r)
    }
}
