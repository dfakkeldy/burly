// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — VolumeStats
//
// Spec §7 #2: weekly total volume (Σ weight × reps, working sets only,
// canonical kg → display unit). Callers own the range filter (8 / 26 / 52
// weeks, §7) via `BurlyStore.loggedSetSlices`'s `since`/`through` — see
// `CalendarBucketing.trailingWeekWindow` for computing an aligned window
// for a named range; this file only buckets and sums whatever it is
// given. See `CalendarBucketing` for why weeks are calendar-aligned (the
// caller's time zone and week-start convention) rather than a fixed UTC
// epoch anchor.
import Foundation

/// One bar on the volume chart.
public struct WeeklyVolume: Sendable, Equatable {
    /// Start of the calendar week this bucket covers (inclusive).
    public let weekStart: Date
    /// Σ weight × reps across the week's working sets, canonical kg.
    public let totalVolumeKg: Double

    /// Display-layer conversion (spec §7: "canonical kg → display unit"),
    /// via `Weight`'s own exact avoirdupois constant — never a second,
    /// independently-rounded conversion factor for volume specifically.
    public var totalVolumeLb: Double {
        totalVolumeKg / Weight.kilogramsPerPound
    }
}

public enum VolumeStats {
    /// Buckets `slices` into calendar weeks (see `CalendarBucketing`) and
    /// sums `weight.kg × reps` over each week's **working** sets — warmups
    /// are excluded (spec §7: "everywhere"). Weeks with no working sets
    /// produce no bucket; the result is sorted ascending by `weekStart`.
    ///
    /// - Parameter calendar: the user's calendar (time zone + week-start
    ///   convention) that defines what a "week" is — mandatory rather
    ///   than a hardcoded UTC epoch week (m6-01 fix round 1, major #3;
    ///   see `CalendarBucketing`'s doc).
    ///
    /// Sums with Kahan compensated summation, one running compensation
    /// term per week bucket (m6-01 fix round 1, minor: deterministic
    /// summation). `BurlyStore.loggedSetSlices` promises no fetch
    /// ordering, and naive `+=` accumulation over binary64 is not
    /// associative — the same set of SetRecords, summed in two different
    /// orders, measurably produced two different totals (25,002,500 vs.
    /// 25,002,500.000037253 for 25,000 contributions of 1000 and 25,000 of
    /// 0.1). Kahan summation was chosen over "sort the slices into a
    /// canonical order first" because it is not just order-stable but
    /// materially more accurate at this scale, and it costs one extra
    /// running `Double` per bucket rather than a sort.
    public static func weeklyVolume(from slices: [SetRecordSlice], calendar: Calendar) -> [WeeklyVolume] {
        var totals: [Date: Double] = [:]
        var compensations: [Date: Double] = [:]
        for slice in slices where !slice.set.isWarmup {
            let weekStart = CalendarBucketing.weekStart(for: slice.set.completedAt, calendar: calendar)
            let value = slice.set.weight.kg * Double(slice.set.reps)

            let sum = totals[weekStart, default: 0]
            let compensation = compensations[weekStart, default: 0]
            let adjustedValue = value - compensation
            let newSum = sum + adjustedValue
            compensations[weekStart] = (newSum - sum) - adjustedValue
            totals[weekStart] = newSum
        }
        return totals
            .map { WeeklyVolume(weekStart: $0.key, totalVolumeKg: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }
}
