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

    /// See `ConsistencyStatsTests.utcThursdayCalendar`'s doc: a
    /// Thursday-start UTC calendar's week boundaries coincide with this
    /// fixture's epoch-based constants, since 1970-01-01 is itself a
    /// Thursday — so these tests keep their hand-computed numbers while
    /// genuinely exercising `CalendarBucketing`'s calendar-aware bucketing
    /// (m6-01 fix round 1, major #3) via an explicit, deterministic
    /// `Calendar` rather than a hardcoded UTC/epoch anchor.
    private static var utcThursdayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 5
        return calendar
    }

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

        let volume = VolumeStats.weeklyVolume(from: slices, calendar: Self.utcThursdayCalendar)
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
        let volume = VolumeStats.weeklyVolume(from: slices, calendar: Self.utcThursdayCalendar)
        #expect(volume.count == 1)
        #expect(volume[0].weekStart == Self.weekZeroStart)
    }

    @Test("kg → lb display conversion uses Weight's exact avoirdupois constant")
    func displayUnitConversion() {
        let volume = VolumeStats.weeklyVolume(
            from: [Self.slice(offsetSeconds: 0, weightKg: 1_000, reps: 1)],
            calendar: Self.utcThursdayCalendar
        )
        // 1000 kg / 0.45359237 = 2204.622621848... lb.
        #expect(abs(volume[0].totalVolumeLb - 2_204.622_621_85) < 0.000_1)
    }

    @Test("no working sets in the window produces no buckets at all")
    func emptyInputProducesNoBuckets() {
        #expect(VolumeStats.weeklyVolume(from: [], calendar: Self.utcThursdayCalendar).isEmpty)
    }

    // MARK: - Minor fix: deterministic (Kahan) summation

    @Test("the same SetRecords sum to the identical total regardless of fetch order (minor fix: deterministic summation)")
    func summationIsOrderIndependent() {
        // The review's exact reproduction: 25,000 contributions of 1000 kg
        // (a 1000×1 set) and 25,000 of 0.1 kg (a 0.1×1 set), all in week 0.
        // Naive `+=` accumulation measurably produced 25,002,500.000037253
        // in one order and exactly 25,002,500 in the reverse order — two
        // different numbers for the same underlying history, because
        // `BurlyStore.loggedSetSlices` promises no fetch ordering.
        var forwardOrder: [SetRecordSlice] = []
        for _ in 0..<25_000 {
            forwardOrder.append(Self.slice(offsetSeconds: 0, weightKg: 1_000, reps: 1))
        }
        for _ in 0..<25_000 {
            forwardOrder.append(Self.slice(offsetSeconds: 0, weightKg: 0.1, reps: 1))
        }
        let reverseOrder = Array(forwardOrder.reversed())

        let forwardVolume = VolumeStats.weeklyVolume(from: forwardOrder, calendar: Self.utcThursdayCalendar)
        let reverseVolume = VolumeStats.weeklyVolume(from: reverseOrder, calendar: Self.utcThursdayCalendar)

        #expect(forwardVolume.count == 1)
        #expect(reverseVolume.count == 1)
        // Bit-identical, not just "close enough" — and correct: exactly
        // 25,000×1000 + 25,000×0.1 = 25,002,500.
        #expect(forwardVolume[0].totalVolumeKg == reverseVolume[0].totalVolumeKg)
        #expect(forwardVolume[0].totalVolumeKg == 25_002_500)
    }

    // MARK: - Review round 2, item 8 fix: deterministic pre-sort makes the total order-independent for ANY permutation, not just forward/reverse

    /// A minimal, self-contained xorshift64 RNG so this file doesn't need a
    /// dependency on BurlyFixtures' `SeededGenerator` just to produce a
    /// handful of reproducible shuffles.
    private struct DeterministicRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E37_79B9 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @Test("weeklyVolume's total is bit-identical across many random shuffles of the same slices, not just forward/reverse order (review round 2, item 8 fix)")
    func summationIsIdenticalAcrossArbitraryShuffles() {
        // A richer fixture than the forward/reverse test above: 200 sets
        // with varied weight/rep/timestamp combinations, all within one
        // week, so a summation that is merely order-*stable* for two
        // specific orderings (forward and its exact reverse) but not truly
        // order-*independent* has many more chances to disagree.
        var slices: [SetRecordSlice] = []
        for i in 0..<200 {
            slices.append(
                Self.slice(
                    offsetSeconds: Double(i % 5) * 3_600,
                    weightKg: Double(i % 37) + 0.1,
                    reps: (i % 12) + 1
                )
            )
        }

        let baseline = VolumeStats.weeklyVolume(from: slices, calendar: Self.utcThursdayCalendar)
        #expect(baseline.count == 1)

        for seed in UInt64(1)...5 {
            var rng = DeterministicRNG(seed: seed)
            let shuffled = slices.shuffled(using: &rng)
            let result = VolumeStats.weeklyVolume(from: shuffled, calendar: Self.utcThursdayCalendar)
            #expect(result == baseline)
        }
    }

    // MARK: - Major #5 fix: named 8-week range produces exactly 8 buckets

    @Test("an 8-week named range produces exactly 8 volume buckets, not 9 (major #5 fix)")
    func namedEightWeekRangeProducesExactlyEightBuckets() {
        // The review's exact failing shape: `asOf` sits three days into
        // its own week (the 8th week of the range), so the naive
        // `since = asOf - 8×7 days` lands mid-week rather than on a
        // boundary, and an inclusive `[since, through]` filter spans 9
        // week-start buckets instead of 8.
        let asOf = Self.weekZeroStart
            .addingTimeInterval(8 * Self.weekLength)
            .addingTimeInterval(3 * 86_400)

        let (since, through) = CalendarBucketing.trailingWeekWindow(
            weekCount: 8,
            asOf: asOf,
            calendar: Self.utcThursdayCalendar
        )

        // One working set at the start of each of the 8 weeks the window
        // is supposed to cover.
        var slices: [SetRecordSlice] = []
        var cursor = since
        for _ in 0..<8 {
            let offset = cursor.timeIntervalSince(Self.weekZeroStart)
            slices.append(Self.slice(offsetSeconds: offset, weightKg: 10, reps: 1))
            cursor = Self.utcThursdayCalendar.date(byAdding: .weekOfYear, value: 1, to: cursor)!
        }

        let filtered = slices.filter { $0.set.completedAt >= since && $0.set.completedAt <= through }
        #expect(filtered.count == 8) // nothing in the fixture fell outside the window

        let volume = VolumeStats.weeklyVolume(from: filtered, calendar: Self.utcThursdayCalendar)
        #expect(volume.count == 8)
    }
}
