// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — VolumeStats
//
// Spec §7 #2: weekly total volume (Σ weight × reps, working sets only,
// canonical kg → display unit). Callers own the range filter (8 / 26 / 52
// weeks, §7) via `BurlyStore.loggedSetSlices`'s `since`/`through`; this
// file only buckets and sums whatever it is given. See EpochBucketing.swift
// for why weeks are epoch-aligned rather than local-calendar-aligned.
import Foundation

/// One bar on the volume chart.
public struct WeeklyVolume: Sendable, Equatable {
    /// Start of the epoch-aligned week this bucket covers (inclusive).
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
    /// Buckets `slices` into epoch-aligned weeks (see `EpochBucketing`) and
    /// sums `weight.kg × reps` over each week's **working** sets — warmups
    /// are excluded (spec §7: "everywhere"). Weeks with no working sets
    /// produce no bucket; the result is sorted ascending by `weekStart`.
    public static func weeklyVolume(from slices: [SetRecordSlice]) -> [WeeklyVolume] {
        var totals: [Date: Double] = [:]
        for slice in slices where !slice.set.isWarmup {
            let weekStart = EpochBucketing.bucketStart(for: slice.set.completedAt, length: EpochBucketing.weekLength)
            totals[weekStart, default: 0] += slice.set.weight.kg * Double(slice.set.reps)
        }
        return totals
            .map { WeeklyVolume(weekStart: $0.key, totalVolumeKg: $0.value) }
            .sorted { $0.weekStart < $1.weekStart }
    }
}
