// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for VolumeStats (spec §7 #2, acceptance #1): weekly
// bucketing, warmup exclusion, and kg→lb display conversion, all hand-
// computed.
import Testing
import Foundation
@testable import BurlyCore

@Suite("VolumeStats: weekly Σ weight×reps (§7 #2 fixture truth)")
struct VolumeStatsTests {
    // 1970-01-01T00:00:00Z — an exact epoch-week boundary, so the expected
    // bucket starts below are round numbers instead of an arbitrary offset.
    private static let weekZeroStart = Date(timeIntervalSince1970: 0)
    private static let weekLength: TimeInterval = 7 * 24 * 60 * 60

    private static func slice(offsetSeconds: TimeInterval, weightKg: Double, reps: Int, isWarmup: Bool = false) -> SetRecordSlice {
        let date = weekZeroStart.addingTimeInterval(offsetSeconds)
        return SetRecordSlice(
            sessionID: UUID(),
            sessionStartedAt: date,
            exerciseID: UUID(),
            set: SetRecordData(order: 0, weight: Weight(kg: weightKg), reps: reps, isWarmup: isWarmup, completedAt: date)
        )
    }

    @Test("two sets in week 0, one in week 1; a week-0 warmup is excluded from the total")
    func weeklyBucketingAndWarmupExclusion() {
        let slices = [
            // Week 0: 100×5 (=500) + 50×10 (=500) = 1000 kg.
            Self.slice(offsetSeconds: 0, weightKg: 100, reps: 5),
            Self.slice(offsetSeconds: 3 * 86_400, weightKg: 50, reps: 10),
            // Would add 100,000 kg if wrongly included — proves exclusion,
            // not just that the fixture happens not to need it.
            Self.slice(offsetSeconds: 3 * 86_400, weightKg: 1_000, reps: 100, isWarmup: true),
            // Exactly the week-1 boundary: 80×8 = 640 kg.
            Self.slice(offsetSeconds: Self.weekLength, weightKg: 80, reps: 8)
        ]

        let volume = VolumeStats.weeklyVolume(from: slices)
        #expect(volume.count == 2)

        #expect(volume[0].weekStart == Self.weekZeroStart)
        #expect(volume[0].totalVolumeKg == 1000)

        #expect(volume[1].weekStart == Self.weekZeroStart.addingTimeInterval(Self.weekLength))
        #expect(volume[1].totalVolumeKg == 640)
    }

    @Test("a set one second before the week boundary still buckets into week 0, not week 1")
    func lastSecondOfAWeekStaysInThatWeek() {
        let slices = [
            Self.slice(offsetSeconds: Self.weekLength - 1, weightKg: 10, reps: 1)
        ]
        let volume = VolumeStats.weeklyVolume(from: slices)
        #expect(volume.count == 1)
        #expect(volume[0].weekStart == Self.weekZeroStart)
    }

    @Test("kg → lb display conversion uses Weight's exact avoirdupois constant")
    func displayUnitConversion() {
        let volume = VolumeStats.weeklyVolume(from: [
            Self.slice(offsetSeconds: 0, weightKg: 1_000, reps: 1)
        ])
        // 1000 kg / 0.45359237 = 2204.622621848... lb.
        #expect(abs(volume[0].totalVolumeLb - 2_204.622_621_85) < 0.000_1)
    }

    @Test("no working sets in the window produces no buckets at all")
    func emptyInputProducesNoBuckets() {
        #expect(VolumeStats.weeklyVolume(from: []).isEmpty)
    }
}
