// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — TrailingWindow
//
// m6-01 fix round 2, review item 7: the previous fix round closed the
// all-nil sentinel bypass (`.distantPast`) with a runtime nil-check, but a
// runtime check on an *optional* `Date` cannot actually stop a caller from
// passing a non-nil sentinel that means the same thing — `since:
// .distantPast` satisfies "not nil" while still fetching the whole table.
// The review's verdict: enforce the bound by API *shape*, not by another
// runtime guard.
//
// `TrailingWindow` is that shape for the one stats query that has no
// exercise dimension to bound it the other way (`BurlyStore.loggedSetSlices`
// for volume/muscle-split's "all exercises" charts — see that method's
// `window:through:calendar:` overload). There is no `Date` anywhere in its
// public API: only a small, closed set of named constructors that validate
// positivity and an upper bound at construction time. A caller cannot
// construct a `TrailingWindow` that means "unbounded" the way `nil` or
// `.distantPast` could, so there is nothing left to sneak past.
import Foundation

public struct TrailingWindow: Sendable, Equatable {
    fileprivate enum Kind: Equatable {
        case days(Int)
        case weeks(Int)
    }

    fileprivate let kind: Kind

    /// The longest span any current §7 range needs — volume's longest
    /// named range is 52 weeks (364 days, spec §7 #2) — plus real headroom
    /// for a future range within the same order of magnitude. Generous
    /// enough that today's named ranges (and a plausible next one) fit
    /// comfortably; tight enough that this stays a meaningfully bounded
    /// window rather than "all-time wearing a trenchcoat." Not a spec
    /// number — this task's documented choice, the same way
    /// `ExerciseProgressionStats.e1RMRelativeEpsilon` is.
    public static let maxDays = 400

    private init(kind: Kind) {
        self.kind = kind
    }

    /// - Precondition: `count` is positive and does not exceed `maxDays`.
    public static func days(_ count: Int) -> TrailingWindow {
        precondition(count > 0, "TrailingWindow.days requires count > 0, got \(count)")
        precondition(count <= maxDays, "TrailingWindow.days requires count <= \(maxDays), got \(count)")
        return TrailingWindow(kind: .days(count))
    }

    /// - Precondition: `count` is positive and `count * 7` does not exceed
    ///   `maxDays`.
    public static func weeks(_ count: Int) -> TrailingWindow {
        precondition(count > 0, "TrailingWindow.weeks requires count > 0, got \(count)")
        precondition(count * 7 <= maxDays, "TrailingWindow.weeks requires count * 7 <= \(maxDays), got \(count)")
        return TrailingWindow(kind: .weeks(count))
    }

    /// The concrete `[since, through]` date range this window describes,
    /// ending at `referenceDate` — the store's own conversion step (see
    /// `BurlyStore.loggedSetSlices(window:through:calendar:)`), not
    /// something a caller computes by hand.
    ///
    /// Calendar-aligned, not a raw `referenceDate - N` offset (m6-01 fix
    /// round 1, major #5 already established why for weeks —
    /// `CalendarBucketing.trailingWeekWindow` — and the same reasoning
    /// applies to days: an unaligned bound can pull in one extra partial
    /// bucket at the edge, which is exactly the "8 weeks produces 9 bars"
    /// bug that fix closed).
    public func dateRange(asOf referenceDate: Date, calendar: Calendar) -> (since: Date, through: Date) {
        switch kind {
        case .weeks(let count):
            return CalendarBucketing.trailingWeekWindow(weekCount: count, asOf: referenceDate, calendar: calendar)
        case .days(let count):
            return CalendarBucketing.trailingDayWindow(dayCount: count, asOf: referenceDate, calendar: calendar)
        }
    }
}
