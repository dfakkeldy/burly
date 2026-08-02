// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture-truth tests for ExerciseProgressionStats (spec §7 #1, acceptance
// #1): every number below is hand-computed against a synthetic three-
// session history, not derived by mirroring the implementation.
import Testing
import Foundation
@testable import BurlyCore

@Suite("ExerciseProgressionStats: PRs and Epley e1RM (§7 #1 fixture truth)")
struct ExerciseProgressionStatsTests {
    private static let exerciseID = UUID()
    private static let day0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day1 = day0.addingTimeInterval(86_400)
    private static let day2 = day0.addingTimeInterval(2 * 86_400)

    private static let sessionA = UUID()
    private static let sessionB = UUID()
    private static let sessionC = UUID()

    /// Session A: a 120 kg warmup (heavier than every working set — proves
    /// exclusion actually matters, not just that it's a no-op), then two
    /// working sets. Session B: two working sets, one of which pushes the
    /// top-weight PR and the other the e1RM PR. Session C: one working set
    /// that beats neither running maximum, so it produces no PR.
    private static func slice(session: UUID, date: Date, weightKg: Double, reps: Int, isWarmup: Bool = false) -> SetRecordSlice {
        SetRecordSlice(
            sessionID: session,
            sessionStartedAt: date,
            exerciseID: exerciseID,
            set: SetRecordData(order: 0, weight: Weight(kg: weightKg), reps: reps, isWarmup: isWarmup, completedAt: date)
        )
    }

    private static let slices: [SetRecordSlice] = [
        slice(session: sessionA, date: day0, weightKg: 120, reps: 1, isWarmup: true),
        slice(session: sessionA, date: day0, weightKg: 100, reps: 5),
        slice(session: sessionA, date: day0, weightKg: 90, reps: 8),
        slice(session: sessionB, date: day1, weightKg: 95, reps: 10),
        slice(session: sessionB, date: day1, weightKg: 110, reps: 3),
        slice(session: sessionC, date: day2, weightKg: 105, reps: 5)
    ]

    @Test("Epley: w × (1 + reps/30), exactly the spec formula")
    func epleyFormula() {
        // 100 × (1 + 5/30) = 100 × 35/30 = 116.666...
        let e1rm = ExerciseProgressionStats.epleyEstimatedOneRepMax(weight: Weight(kg: 100), reps: 5)
        #expect(abs(e1rm - 116.666_666_67) < 0.000_01)
    }

    @Test("one point per session; the warmup's 120 kg is excluded from session A's top weight")
    func sessionPointsExcludeWarmup() {
        let points = ExerciseProgressionStats.sessionPoints(from: Self.slices)
        #expect(points.count == 3)

        let a = points[0]
        #expect(a.sessionID == Self.sessionA)
        #expect(a.date == Self.day0)
        // 100 kg, not 120 — the warmup does not count as the top set.
        #expect(a.topWeight.kg == 100)
        // best e1RM among {100×5, 90×8}: 116.667 vs 90×(1+8/30)=114.0.
        #expect(abs(a.estimatedOneRepMax - 116.666_666_67) < 0.000_01)

        let b = points[1]
        #expect(b.sessionID == Self.sessionB)
        // top weight is the 110 kg single, not the 95 kg×10.
        #expect(b.topWeight.kg == 110)
        // best e1RM: 95×(1+10/30)=126.667 beats 110×(1+3/30)=121.0 — the
        // higher-rep, lower-weight set produces the better estimate.
        #expect(abs(b.estimatedOneRepMax - 126.666_666_67) < 0.000_01)

        let c = points[2]
        #expect(c.sessionID == Self.sessionC)
        #expect(c.topWeight.kg == 105)
        #expect(abs(c.estimatedOneRepMax - 122.5) < 0.000_01)
    }

    @Test("PRs: session A sets both initial records, session B beats both, session C beats neither")
    func personalRecordsTrackBothSeriesIndependently() {
        let points = ExerciseProgressionStats.sessionPoints(from: Self.slices)
        let records = ExerciseProgressionStats.personalRecords(from: points)

        #expect(records.count == 4)

        #expect(records[0].sessionID == Self.sessionA)
        #expect(records[0].kind == .topWeight)
        #expect(records[0].value == 100)

        #expect(records[1].sessionID == Self.sessionA)
        #expect(records[1].kind == .estimatedOneRepMax)
        #expect(abs(records[1].value - 116.666_666_67) < 0.000_01)

        #expect(records[2].sessionID == Self.sessionB)
        #expect(records[2].kind == .topWeight)
        #expect(records[2].value == 110)

        #expect(records[3].sessionID == Self.sessionB)
        #expect(records[3].kind == .estimatedOneRepMax)
        #expect(abs(records[3].value - 126.666_666_67) < 0.000_01)

        // Session C's 105 kg / 122.5 e1RM beats neither running max
        // (110 kg / 126.667), so it contributes no record.
        #expect(records.allSatisfy { $0.sessionID != Self.sessionC })
    }

    @Test("a session with only a warmup set produces no point at all")
    func warmupOnlySessionProducesNoPoint() {
        let warmupOnlySession = UUID()
        let slices = [
            Self.slice(session: warmupOnlySession, date: Self.day0, weightKg: 999, reps: 1, isWarmup: true)
        ]
        #expect(ExerciseProgressionStats.sessionPoints(from: slices).isEmpty)
    }

    @Test("a tie does not count as a new PR — the spec's 'new' is strict")
    func tieIsNotANewRecord() {
        let s1 = UUID()
        let s2 = UUID()
        let slices = [
            Self.slice(session: s1, date: Self.day0, weightKg: 100, reps: 5),
            Self.slice(session: s2, date: Self.day1, weightKg: 100, reps: 5)
        ]
        let points = ExerciseProgressionStats.sessionPoints(from: slices)
        let records = ExerciseProgressionStats.personalRecords(from: points)
        // Only session 1 sets records; session 2 exactly ties both series.
        #expect(records.filter { $0.sessionID == s1 }.count == 2)
        #expect(records.filter { $0.sessionID == s2 }.isEmpty)
    }

    // MARK: - Major #2 fix: mathematically-tied Epley estimates are not a false PR

    @Test("mathematically-identical Epley estimates that differ at the binary64 ULP level do not produce a false PR (major #2 fix)")
    func floatTiedEpleyEstimatesDoNotProduceFalsePR() {
        // 87.5 kg × 10 and 100 kg × 5 are both exactly 3500/30 — the same
        // Epley estimate — but binary64 evaluates the two multiplications
        // to values that differ by ~1.4e-14.
        let s1 = UUID()
        let s2 = UUID()
        let slices = [
            Self.slice(session: s1, date: Self.day0, weightKg: 87.5, reps: 10),
            Self.slice(session: s2, date: Self.day1, weightKg: 100, reps: 5)
        ]
        let points = ExerciseProgressionStats.sessionPoints(from: slices)

        // Sanity: the two raw estimates really do differ at the `Double`
        // level — otherwise this fixture would not exercise the float-tie
        // bug at all, it would just be an ordinary exact tie.
        #expect(points[0].estimatedOneRepMax != points[1].estimatedOneRepMax)

        let records = ExerciseProgressionStats.personalRecords(from: points)
        // Only session 1 sets the e1RM record; session 2's estimate
        // quantizes to the same value, so it is a tie, not a new PR.
        #expect(records.filter { $0.kind == .estimatedOneRepMax }.count == 1)
        #expect(records.first { $0.kind == .estimatedOneRepMax }?.sessionID == s1)
    }

    // MARK: - Major #3 fix: PRs are computed over all-time history, then filtered to the display range

    @Test("an out-of-range session's all-time record suppresses a false PR inside the displayed range (major #3 fix)")
    func rangeRelativeFalsePRsAreFilteredAfterComputingOverAllTimeHistory() {
        let oldSession = UUID()
        let recentSession = UUID()
        // Well outside any plausible displayed range.
        let oldDate = Self.day0.addingTimeInterval(-500 * 86_400)
        let recentDate = Self.day0

        let allTimeSlices = [
            // All-time best on both series: e1RM 120×(1+5/30) = 140.
            Self.slice(session: oldSession, date: oldDate, weightKg: 120, reps: 5),
            // Beats neither all-time record (100 < 120; e1RM 116.67 < 140).
            Self.slice(session: recentSession, date: recentDate, weightKg: 100, reps: 5)
        ]
        let allTimePoints = ExerciseProgressionStats.sessionPoints(from: allTimeSlices)

        let displayRange = recentDate.addingTimeInterval(-1)...recentDate.addingTimeInterval(1)
        let records = ExerciseProgressionStats.personalRecords(from: allTimePoints, displayRange: displayRange)

        // The recent session is the only one inside the displayed range,
        // but it is not an all-time PR on either series, so nothing
        // should be reported for it — even though a caller who had
        // (wrongly) pre-filtered to the display range before calling this
        // function would have started both running maxima at -infinity
        // at the range's edge and reported it as both kinds of PR.
        #expect(records.isEmpty)
    }

    @Test("a record from before the display range is not included in the filtered output, even though it is still real")
    func recordsOutsideDisplayRangeAreExcludedFromOutput() {
        let oldSession = UUID()
        let recentSession = UUID()
        let oldDate = Self.day0.addingTimeInterval(-500 * 86_400)
        let recentDate = Self.day0

        let allTimeSlices = [
            Self.slice(session: oldSession, date: oldDate, weightKg: 120, reps: 5),
            // Beats both all-time records.
            Self.slice(session: recentSession, date: recentDate, weightKg: 130, reps: 5)
        ]
        let allTimePoints = ExerciseProgressionStats.sessionPoints(from: allTimeSlices)

        let displayRange = recentDate.addingTimeInterval(-1)...recentDate.addingTimeInterval(1)
        let records = ExerciseProgressionStats.personalRecords(from: allTimePoints, displayRange: displayRange)

        // The old session's own initial records are real but predate the
        // displayed range and must not appear in it.
        #expect(records.allSatisfy { $0.sessionID != oldSession })
        // The recent session genuinely broke both all-time records and is
        // inside the range, so both of its records are present.
        #expect(records.filter { $0.sessionID == recentSession }.count == 2)
    }

    // MARK: - Minor fix: personalRecords sorts internally

    @Test("personalRecords sorts internally rather than trusting caller order (minor fix)")
    func personalRecordsSortsInternallyRegardlessOfInputOrder() {
        let points = ExerciseProgressionStats.sessionPoints(from: Self.slices)
        let reversed = Array(points.reversed())

        // Sanity: this really is out of chronological order.
        #expect(reversed.first?.date != points.first?.date || reversed.count <= 1)

        let recordsFromSorted = ExerciseProgressionStats.personalRecords(from: points)
        let recordsFromReversed = ExerciseProgressionStats.personalRecords(from: reversed)

        #expect(recordsFromReversed == recordsFromSorted)
    }

    // MARK: - Nit: one-series-only PR fixtures

    @Test("a session can break only the top-weight series, and another only the e1RM series (nit fixture)")
    func oneSeriesOnlyPersonalRecords() {
        let s1 = UUID()
        let s2 = UUID()
        let s3 = UUID()
        let slices = [
            // Initial PRs on both series: top weight 100, e1RM 133.33.
            Self.slice(session: s1, date: Self.day0, weightKg: 100, reps: 10),
            // Breaks ONLY top weight: 110 > 100, but e1RM 110×(1+1/30) =
            // 113.67 < 133.33.
            Self.slice(session: s2, date: Self.day1, weightKg: 110, reps: 1),
            // Breaks ONLY e1RM: 105 < 110 (no top-weight PR), but
            // 105×(1+10/30) = 140 > 133.33.
            Self.slice(session: s3, date: Self.day2, weightKg: 105, reps: 10)
        ]
        let points = ExerciseProgressionStats.sessionPoints(from: slices)
        let records = ExerciseProgressionStats.personalRecords(from: points)

        #expect(records.filter { $0.sessionID == s1 }.count == 2)

        let s2Records = records.filter { $0.sessionID == s2 }
        #expect(s2Records.count == 1)
        #expect(s2Records.first?.kind == .topWeight)

        let s3Records = records.filter { $0.sessionID == s3 }
        #expect(s3Records.count == 1)
        #expect(s3Records.first?.kind == .estimatedOneRepMax)
    }
}
