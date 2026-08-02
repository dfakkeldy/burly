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
// way. Each shape's grammar is enforced exactly (finding 6.3): a
// component's digit width must match the documented shape (e.g. "2025-6-5"
// is rejected, not silently accepted as "2025-06-05") rather than accepting
// anything `Int.init` happens to parse.
//
// Hand-rolled instead of `DateFormatter`/`ISO8601DateFormatter` for two
// reasons: `DateFormatter` is a non-`Sendable` reference type, awkward to
// hold as shared state under this package's Swift 6 strict concurrency
// mode; and the two formats above are simple enough that hand-parsing is
// both easy to get right and easy to lock down against hostile input
// (out-of-range components, overflow, garbage text) without fighting
// locale/calendar edge cases `DateFormatter` would otherwise paper over.
//
// TIMEZONE (finding 6.1): Hevy's CSV carries no timezone information at
// all — both formats above are timezone-less wall-clock text. Earlier
// versions of this module silently assumed UTC unconditionally. `parse`
// now takes an explicit `timeZone:` parameter (default `defaultTimeZone`,
// UTC) instead: the assumption is surfaced as a documented, overridable
// default rather than hidden, and a caller who knows the export device's
// real timezone can pass it to avoid a multi-hour shift versus the
// wall-clock time Hevy actually displayed.
import Foundation

/// `public` (rather than the module-internal visibility every other type in
/// this file's neighborhood has) solely so `defaultTimeZone` below can back
/// a default argument value on `HevyCSVImporter.parse`'s public
/// `timeZone:` parameter — Swift requires a default argument expression to
/// be at least as visible as the API it defaults. `parse(_:timeZone:)` and
/// `canonicalKey(for:)` are exposed for the same reason; nothing outside
/// BurlyImport is expected to call them directly.
public enum HevyTimestamp {
    /// Timezone used to interpret a timezone-less timestamp when a caller
    /// doesn't pass one explicitly (finding 6.1). UTC matches this
    /// module's original assumption; it's now an explicit, overridable
    /// default instead of a hidden one.
    public static let defaultTimeZone = TimeZone(identifier: "UTC")!

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static let monthAbbreviations: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    /// Parses `text` against both known shapes (see file doc), interpreting
    /// a timezone-less value in `timeZone` (finding 6.1). Returns `nil` for
    /// anything that matches neither shape's exact grammar (finding 6.3) —
    /// including well-formed-looking but impossible dates like "31 Feb
    /// 2025" or "2025-13-01 00:00:00", which `validated(_:timeZone:)` below
    /// explicitly rejects rather than letting `Calendar` silently roll them
    /// into a different, valid date.
    public static func parse(_ text: String, timeZone: TimeZone = defaultTimeZone) -> Date? {
        isoLike(text, timeZone: timeZone) ?? hevyStyle(text, timeZone: timeZone)
    }

    /// A canonical, locale- and input-format-independent representation of
    /// an already-parsed instant: whole seconds since the Unix epoch.
    /// Finding 2.2: session identity is hashed from this instead of the
    /// raw accepted lexeme, so the same instant exported once as
    /// "yyyy-MM-dd HH:mm:ss" and again as "d MMM yyyy, HH:mm" (or any two
    /// re-exports using either format) hashes to the same session ID.
    /// Whole seconds loses nothing: neither supported format carries
    /// sub-second precision.
    public static func canonicalKey(for date: Date) -> String {
        String(Int(date.timeIntervalSince1970.rounded()))
    }

    /// `yyyy-MM-dd HH:mm:ss`
    private static func isoLike(_ text: String, timeZone: TimeZone) -> Date? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 3,
              isExactDigits(dateParts[0], count: 4), let year = Int(dateParts[0]),
              isExactDigits(dateParts[1], count: 2), let month = Int(dateParts[1]),
              isExactDigits(dateParts[2], count: 2), let day = Int(dateParts[2]),
              isExactDigits(timeParts[0], count: 2), let hour = Int(timeParts[0]),
              isExactDigits(timeParts[1], count: 2), let minute = Int(timeParts[1]),
              isExactDigits(timeParts[2], count: 2), let second = Int(timeParts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return validated(components, timeZone: timeZone)
    }

    /// `d MMM yyyy, HH:mm` (e.g. "22 Dec 2025, 08:00")
    private static func hevyStyle(_ text: String, timeZone: TimeZone) -> Date? {
        let commaParts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard commaParts.count == 2 else { return nil }

        // Finding 6.3 (round-2 follow-up): `omittingEmptySubsequences:
        // false` here (rather than the `true` used elsewhere in this file
        // for splitting on a delimiter that legitimately never repeats) is
        // deliberate — the documented grammar is exactly ONE space between
        // `d`, `MMM`, and `yyyy`. An internal double space (e.g.
        // "2  Jan 2025") produces an empty token between two real ones,
        // pushing the count to 4 and failing the guard below instead of
        // silently tolerating a shape that was never one of the two
        // documented/supported formats.
        let dateTokens = commaParts[0]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: false)
        guard dateTokens.count == 3,
              isExactDigits(dateTokens[0], countRange: 1...2), let day = Int(dateTokens[0]),
              dateTokens[1].count == 3, let month = monthAbbreviations[dateTokens[1].lowercased()],
              isExactDigits(dateTokens[2], count: 4), let year = Int(dateTokens[2])
        else { return nil }

        let timeTokens = commaParts[1]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard timeTokens.count == 2,
              isExactDigits(timeTokens[0], count: 2), let hour = Int(timeTokens[0]),
              isExactDigits(timeTokens[1], count: 2), let minute = Int(timeTokens[1])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return validated(components, timeZone: timeZone)
    }

    /// Finding 6.3: rejects a numeric token whose digit width doesn't
    /// exactly match the documented grammar (e.g. "6" where the shape
    /// requires a 2-digit month) instead of accepting anything
    /// `Int.init` can parse — a loosely-padded shape was never one of the
    /// two documented/supported formats and must be reported as malformed,
    /// not silently normalized into a valid date.
    private static func isExactDigits(_ token: Substring, count: Int) -> Bool {
        token.count == count && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isExactDigits(_ token: Substring, countRange: ClosedRange<Int>) -> Bool {
        countRange.contains(token.count) && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Rejects out-of-range components. `Calendar.date(from:)` normalizes
    /// an invalid day/month (e.g. "32 Jan" or "31 Feb") into a *different*,
    /// valid date rather than failing — round-tripping through
    /// `dateComponents(_:from:)` and comparing catches that instead of
    /// silently turning garbage input into a plausible-looking wrong date.
    private static func validated(_ components: DateComponents, timeZone: TimeZone) -> Date? {
        let cal = calendar(timeZone: timeZone)
        guard let date = cal.date(from: components) else { return nil }
        let roundTrip = cal.dateComponents(
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
