// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — CalendarBucketing
//
// Shared day/week bucketing for §7's volume and consistency charts.
//
// m6-01 fix round 1 (cross-engine adversarial review, major #3 — this file
// replaces `EpochBucketing`): the original implementation bucketed by
// fixed, UTC-epoch-aligned 7-day windows, independent of the caller's
// calendar or time zone. That is wrong for a user-facing "sessions this
// week" or "calendar dot" chart: in any time zone that isn't UTC, a fixed
// UTC day/week boundary falls in the middle of a local day, so two
// sessions on the same local Saturday evening can land in different
// UTC-day buckets, and a "week" boundary can fall mid-evening on some
// local weekday rather than at a calendar week start. Spec §7 says
// "weekly" and "calendar dots"; the product intent is the user's own local
// calendar day and week, not a UTC implementation convenience that
// happened to be simpler to hand-compute in a fixture.
//
// So bucketing now takes an explicit `Calendar` — which carries both the
// time zone (`calendar.timeZone`) and the week-start convention
// (`calendar.firstWeekday`) — rather than hardcoding UTC and an epoch
// anchor nobody chose on purpose. Fixture-truth tests stay deterministic
// by constructing a fixed `Calendar` (explicit `timeZone`, explicit
// `firstWeekday`) and passing it in, exactly the way they already pass a
// fixed reference `Date` instead of `Date()` — determinism comes from the
// test pinning its inputs, not from the production code hardcoding one.
import Foundation

public enum CalendarBucketing {
    /// Start of the calendar day containing `date`, in `calendar`'s time
    /// zone. Thin wrapper over `Calendar.startOfDay(for:)` so every §7
    /// caller goes through one bucketing surface instead of some going
    /// straight to `Calendar` and others not.
    public static func dayStart(for date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Start of the calendar week containing `date`, honoring
    /// `calendar.firstWeekday` and `calendar.timeZone` — never a fixed
    /// Thursday/UTC epoch week.
    public static func weekStart(for date: Date, calendar: Calendar) -> Date {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return interval.start
        }
        // `dateInterval(of:for:)` returns `nil` only when the calendar
        // can't answer the query at all (not a case any `Calendar`
        // identifier this app ships hits in practice). Falling back to
        // the day start rather than trapping keeps this total — a
        // coarser bucket beats a crash in a stats display path.
        return dayStart(for: date, calendar: calendar)
    }

    /// The `[since, through]` window — both inclusive, matching
    /// `BurlyStore.loggedSetSlices`/`loggedSessionDates`'s bound
    /// semantics — that contains exactly `weekCount` calendar-week
    /// buckets: the week containing `asOf`, plus the preceding
    /// `weekCount - 1` calendar weeks. `through` is simply `asOf`: the
    /// current (partial) week never needs a later upper bound, since
    /// nothing after `asOf` exists yet.
    ///
    /// m6-01 fix round 1 (cross-engine review, major #5): the naive
    /// `since = asOf - weekCount × 7 days` does not land on a week
    /// boundary in general — it sits `asOf`'s own offset into its week
    /// short of one — so an inclusive `[since, through]` filter spans
    /// `weekCount + 1` distinct week-start buckets, not `weekCount` (an
    /// `asOf` three days into its week produces bucket starts for that
    /// week *and* the partial week below `since`, i.e. 9 bars for an
    /// "8-week" range). Aligning `since` to the start of the week that is
    /// `weekCount - 1` weeks before `asOf`'s own week closes the gap: the
    /// window covers exactly `weekCount` week-start buckets by
    /// construction, regardless of DST or a calendar whose weeks aren't
    /// exactly 7×86,400 seconds apart.
    public static func trailingWeekWindow(
        weekCount: Int,
        asOf referenceDate: Date,
        calendar: Calendar
    ) -> (since: Date, through: Date) {
        precondition(weekCount > 0, "trailingWeekWindow requires weekCount > 0, got \(weekCount)")
        let currentWeekStart = weekStart(for: referenceDate, calendar: calendar)
        let since = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart)
            ?? currentWeekStart
        return (since, referenceDate)
    }
}
