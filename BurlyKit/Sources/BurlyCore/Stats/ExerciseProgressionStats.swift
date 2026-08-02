// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ExerciseProgressionStats
//
// Spec §7 #1: exercise progression / PRs. Two independently-tracked series
// per exercise, both computed **per session** and both **excluding warmup
// sets** (spec §7: "Warmup sets are excluded from PRs and volume
// everywhere"):
//
// - **top-set weight** — the heaviest working set logged that session.
// - **estimated 1RM** — Epley (`w × (1 + reps/30)`), the *best* estimate
//   among that session's working sets, not the top-set weight's own
//   estimate: a higher-rep set at a lower weight can out-estimate the
//   session's heaviest single, and the spec tracks "new est. 1RM" as its
//   own kind of PR, independent of "new max weight".
//
// "Estimate" is not a cosmetic label (spec §7's honesty doctrine): every
// value this file produces for that series is named `estimatedOneRepMax`,
// never bare `oneRepMax`, so the UI cannot lose the distinction by
// accident.
//
// Callers own the exercise filter — a `BurlyStore.loggedSetSlices` query
// concern, not this file's — but NOT the range filter for PR detection:
// see `personalRecords(from:displayRange:)` below for why "which sessions
// count toward a PR" and "which sessions the chart currently shows" are
// two different questions (m6-01 fix round 1, major #3). Every function
// here operates on whatever slices it is given, in any order, and does
// its own chronological sort.
import Foundation

/// One session's contribution to the exercise-progression chart.
public struct ExerciseSessionPoint: Sendable, Equatable {
    public let sessionID: UUID
    public let date: Date
    /// Heaviest **working** set logged this session, canonical kg.
    public let topWeight: Weight
    /// Best Epley estimate among this session's working sets, kg. Always
    /// labeled "estimate" at display (spec §7 honesty doctrine).
    public let estimatedOneRepMax: Double
}

/// Which series a `PersonalRecord` broke. The spec tracks both
/// independently: "A PR = new max weight or new est. 1RM."
public enum PersonalRecordKind: Sendable, Equatable {
    case topWeight
    case estimatedOneRepMax
}

/// One session that set a new all-time high on one of the two series.
public struct PersonalRecord: Sendable, Equatable {
    public let sessionID: UUID
    public let date: Date
    public let kind: PersonalRecordKind
    /// The new record value, kg — `topWeight.kg` or `estimatedOneRepMax`
    /// depending on `kind`. Always the raw computed value, never the
    /// quantized value used internally to decide ties (see
    /// `personalRecords`'s doc) — display precision is a UI concern.
    public let value: Double
}

public enum ExerciseProgressionStats {
    /// Epley estimated one-rep max (spec §7): `w × (1 + reps/30)`.
    public static func epleyEstimatedOneRepMax(weight: Weight, reps: Int) -> Double {
        weight.kg * (1 + Double(reps) / 30)
    }

    /// One point per session that has at least one working set among
    /// `slices` — a session with only warmup sets for this exercise (or
    /// none at all) produces no point. Chronological ascending by `date`;
    /// ties (same `date`, distinct sessions) break on `sessionID` so the
    /// order is fully deterministic rather than dependent on dictionary
    /// iteration order.
    public static func sessionPoints(from slices: [SetRecordSlice]) -> [ExerciseSessionPoint] {
        var bySession: [UUID: (date: Date, sets: [SetRecordData])] = [:]
        for slice in slices where !slice.set.isWarmup {
            bySession[slice.sessionID, default: (slice.sessionStartedAt, [])].sets.append(slice.set)
        }

        return bySession
            .map { sessionID, entry -> ExerciseSessionPoint in
                // `entry.sets` is never empty here: it only exists because
                // at least one working set was appended to it above.
                let topWeightKg = entry.sets.map { $0.weight.kg }.max() ?? 0
                let bestEstimate = entry.sets
                    .map { epleyEstimatedOneRepMax(weight: $0.weight, reps: $0.reps) }
                    .max() ?? 0
                return ExerciseSessionPoint(
                    sessionID: sessionID,
                    date: entry.date,
                    topWeight: Weight(kg: topWeightKg),
                    estimatedOneRepMax: bestEstimate
                )
            }
            .sorted(by: chronological)
    }

    /// Shared chronological ordering (same `date`, then `sessionID`
    /// string) — `sessionPoints` sorts with it, and `personalRecords`
    /// re-sorts with the identical comparator rather than trusting the
    /// caller already applied it (see that function's doc).
    private static func chronological(_ lhs: ExerciseSessionPoint, _ rhs: ExerciseSessionPoint) -> Bool {
        lhs.date == rhs.date
            ? lhs.sessionID.uuidString < rhs.sessionID.uuidString
            : lhs.date < rhs.date
    }

    /// Relative epsilon for treating two Epley estimates as equal rather
    /// than one being a new record (m6-01 fix round 2, review item 2 —
    /// replaces the round-1 fix's absolute 0.01 kg quantization, which
    /// review round 2 showed suppresses genuine PRs at ordinary plate
    /// increments).
    ///
    /// **Why absolute quantization was wrong:** `46 lb × 2` (`20.86524902
    /// kg`, e1RM `22.2562656213…`) and `47.5 lb × 1` (`21.545637575 kg`,
    /// e1RM `22.2638254942…`) are two different, ordinary half-pound-plate
    /// sets with a genuinely higher second estimate — a real `0.00756 kg`
    /// improvement — but both quantized to `22.26` under the old 0.01 kg
    /// rule, so the second was wrongly dropped as a tie.
    ///
    /// **Why relative epsilon is the right shape:** the float-noise case
    /// this exists to suppress (`87.5 kg × 10` vs. `100 kg × 5`, both
    /// exactly `3500/30`) differs only in binary64 rounding — by
    /// `~1.42e-14` absolute, `~1.22e-16` *relative* to the ~116.67 kg
    /// magnitude of the estimate. The genuine-improvement case above
    /// differs by `~3.4e-4` relative — **twelve orders of magnitude
    /// larger**. `1e-9` sits in the middle of that twelve-decade gap (six
    /// orders of headroom on either side), so it swallows binary64
    /// rounding noise at any realistic e1RM magnitude while registering
    /// any humanly-real weight/rep improvement, however small the plates.
    /// Both figures were computed directly (not estimated) and are pinned
    /// by `ExerciseProgressionStatsTests`:
    /// `floatTiedEpleyEstimatesDoNotProduceFalsePR` (must stay a tie) and
    /// `smallRealisticImprovementRegistersAsANewPR` (must register).
    private static let e1RMRelativeEpsilon: Double = 1e-9

    /// True when `candidate` clears `runningMax` by more than float noise
    /// — i.e. it is a genuine improvement, not a mathematically-equal
    /// estimate that binary64 merely rounded differently.
    ///
    /// `runningMax` starts at `-Double.infinity` (see `personalRecords`
    /// below): that case is handled directly, since scaling an epsilon by
    /// an infinite magnitude would make every finite candidate compare as
    /// "not different enough."
    private static func isGenuineEstimateImprovement(candidate: Double, over runningMax: Double) -> Bool {
        guard runningMax.isFinite else {
            return candidate > runningMax
        }
        guard candidate > runningMax else { return false }
        let scale = max(abs(candidate), abs(runningMax))
        return (candidate - runningMax) > e1RMRelativeEpsilon * scale
    }

    /// Walks `points` chronologically and emits one `PersonalRecord` per
    /// session that **strictly** beats the running maximum on either
    /// series so far — a tie (including a float-tie within
    /// `e1RMRelativeEpsilon`, see above) is not a new record. A single session
    /// can set both kinds; each is reported once, in chronological order.
    ///
    /// - Parameter points: any order — this sorts internally with the
    ///   same comparator `sessionPoints` uses (m6-01 fix round 1, minor:
    ///   a public foundation function should not silently mis-answer a
    ///   caller that hands it unsorted or reverse-sorted points; only
    ///   `sessionPoints` itself is trusted to already be sorted, and even
    ///   it does not skip re-deriving order here).
    /// - Parameter displayRange: when non-`nil`, the returned records are
    ///   narrowed to those whose `date` falls within it — `nil` (the
    ///   default) returns every record, the "all" range's own behavior.
    ///
    ///   **`points` must still be the exercise's full, all-time history,
    ///   never pre-filtered to `displayRange`** (m6-01 fix round 1, major
    ///   #3). PR status is a property of an exercise's entire history, not
    ///   of whatever window a chart happens to be showing: both running
    ///   maxima start at `-infinity`, so if `points` was already cut down
    ///   to (say) the last three months, the first in-range session is
    ///   reported as an all-time PR even when an older, out-of-range
    ///   session already beat it. Computing over full history and
    ///   filtering the resulting *records* down to `displayRange`
    ///   afterward gets the right answer without losing the point — a
    ///   chart showing "3 months" still only draws markers that belong in
    ///   that window.
    ///
    ///   **This function cannot enforce that precondition itself** — it is
    ///   pure BurlyCore and has no store to fetch from, so a caller that
    ///   violates it gets a silently wrong answer back, not an error
    ///   (m6-01 fix round 2, review item 3). Callers with a real
    ///   `BurlyStore` should not re-derive the fetch-then-compute sequence
    ///   by hand; use `BurlyStore.exerciseProgression(exerciseID:
    ///   displayRange:)` instead — it always fetches all-time via
    ///   `loggedSetSlices(exerciseID: id, since: nil, through: nil)` (the
    ///   exercise-bounded, SQL-pushed-down form; SwiftDataStore pushes
    ///   `exerciseID` into the fetch predicate — ~0.5 s at 50k SetRecords
    ///   for one exercise's full history, measured by
    ///   `StatsQueryBenchmarkTests`) regardless of `displayRange`, so the
    ///   precondition can never be violated by going through it. This
    ///   function stays public only for fixture-truth tests that construct
    ///   `[ExerciseSessionPoint]` by hand, with no store in the picture.
    public static func personalRecords(
        from points: [ExerciseSessionPoint],
        displayRange: ClosedRange<Date>? = nil
    ) -> [PersonalRecord] {
        let sortedPoints = points.sorted(by: chronological)

        var runningTopWeightKg = -Double.infinity
        var runningEstimate = -Double.infinity
        var records: [PersonalRecord] = []

        for point in sortedPoints {
            if point.topWeight.kg > runningTopWeightKg {
                runningTopWeightKg = point.topWeight.kg
                records.append(
                    PersonalRecord(sessionID: point.sessionID, date: point.date, kind: .topWeight, value: point.topWeight.kg)
                )
            }
            if isGenuineEstimateImprovement(candidate: point.estimatedOneRepMax, over: runningEstimate) {
                runningEstimate = point.estimatedOneRepMax
                records.append(
                    PersonalRecord(sessionID: point.sessionID, date: point.date, kind: .estimatedOneRepMax, value: point.estimatedOneRepMax)
                )
            }
        }

        guard let displayRange else { return records }
        return records.filter { displayRange.contains($0.date) }
    }
}
