// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyTimestamp
//
// Parses the two known shapes of Hevy's `start_time`/`end_time` columns:
//
//   1. `yyyy-MM-dd HH:mm:ss` — what `BurlyFixtures.HevyCSVGenerator` emits
//      (see that file's header comment: its column shape, including this
//      timestamp format, is an assumption pending m7-03's diff against
//      Dan's real export).
//   2. `d MMM yyyy, HH:mm` (e.g. "22 Dec 2025, 08:00") — the shape a real,
//      recent Hevy export sample uses, per public research at m7-01
//      authorship time (not yet verified against Dan's own export; that
//      verification is m7-03's job).
//
// Trying both keeps the importer working against both this package's own
// fixtures today and a real export later without necessarily needing a
// code change — and if the real shape turns out to differ from both, every
// row simply fails to parse and is reported as malformed (never silently
// misinterpreted), which is the correct hostile-input-safe fallback either
// way.
//
// Hand-rolled instead of `DateFormatter`/`ISO8601DateFormatter` for two
// reasons: `DateFormatter` is a non-`Sendable` reference type, awkward to
// hold as shared state under this package's Swift 6 strict concurrency
// mode; and the two formats above are simple enough that hand-parsing is
// both easy to get right and easy to lock down against hostile input
// (out-of-range components, overflow, garbage text) without fighting
// locale/calendar edge cases `DateFormatter` would otherwise paper over.
//
// Both formats are parsed as literal wall-clock values in a fixed UTC
// calendar: Hevy's CSV carries no timezone information, and Burly only
// needs parsed instants to compare/order/hash consistently with each
// other and across re-imports of the same file — not to reconstruct true
// local time.
import Foundation

enum HevyTimestamp {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let monthAbbreviations: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    /// Parses `text` against both known shapes (see file doc). Returns
    /// `nil` for anything that matches neither — including well-formed-
    /// looking but impossible dates like "31 Feb 2025" or "2025-13-01
    /// 00:00:00", which `validated(_:)` below explicitly rejects rather
    /// than letting `Calendar` silently roll them into a different, valid
    /// date.
    static func parse(_ text: String) -> Date? {
        isoLike(text) ?? hevyStyle(text)
    }

    /// `yyyy-MM-dd HH:mm:ss`
    private static func isoLike(_ text: String) -> Date? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return validated(components)
    }

    /// `d MMM yyyy, HH:mm` (e.g. "22 Dec 2025, 08:00")
    private static func hevyStyle(_ text: String) -> Date? {
        let commaParts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard commaParts.count == 2 else { return nil }

        let dateTokens = commaParts[0]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard dateTokens.count == 3,
              let day = Int(dateTokens[0]),
              let month = monthAbbreviations[dateTokens[1].lowercased()],
              let year = Int(dateTokens[2])
        else { return nil }

        let timeTokens = commaParts[1]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard timeTokens.count == 2,
              let hour = Int(timeTokens[0]), let minute = Int(timeTokens[1])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return validated(components)
    }

    /// Rejects out-of-range components. `Calendar.date(from:)` normalizes
    /// an invalid day/month (e.g. "32 Jan" or "31 Feb") into a *different*,
    /// valid date rather than failing — round-tripping through
    /// `dateComponents(_:from:)` and comparing catches that instead of
    /// silently turning garbage input into a plausible-looking wrong date.
    private static func validated(_ components: DateComponents) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == components.year,
              roundTrip.month == components.month,
              roundTrip.day == components.day,
              roundTrip.hour == components.hour,
              roundTrip.minute == components.minute,
              roundTrip.second == components.second
        else { return nil }
        return date
    }
}
