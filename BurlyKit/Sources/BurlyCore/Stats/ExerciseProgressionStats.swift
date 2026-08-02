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

    /// Quantum for treating two Epley estimates as equal rather than one
    /// being a new record (m6-01 fix round 1, major #2): `87.5 kg × 10`
    /// and `100 kg × 5` are mathematically identical Epley estimates
    /// (`3500 / 30`), but binary64 evaluates the two multiplications to
    /// values that differ by ~1.4e-14 depending on operand order, and a
    /// strict `>` on the raw `Double`s reports the second as a new e1RM
    /// PR. Rounding to the nearest 0.01 kg before comparing absorbs that
    /// noise — many orders of magnitude below where two Epley estimates
    /// could ever differ for a real weight/rep combination (plates load
    /// in 0.25 kg / 0.5 lb steps at the finest) — without merging any
    /// difference a chart could actually render, since no §7 display
    /// shows more than one decimal place. This is this task's documented
    /// choice, not a spec-mandated number.
    private static let e1RMQuantumKg: Double = 0.01

    private static func quantizedEstimate(_ value: Double) -> Double {
        (value / e1RMQuantumKg).rounded() / e1RMQuantumKg
    }

    /// Walks `points` chronologically and emits one `PersonalRecord` per
    /// session that **strictly** beats the running maximum on either
    /// series so far — a tie (including a float-tie within
    /// `e1RMQuantumKg`, see above) is not a new record. A single session
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
    ///   that window. Callers get all-time points via
    ///   `BurlyStore.loggedSetSlices(exerciseID: id, since: nil, through:
    ///   nil)` — the exercise-bounded, SQL-pushed-down form (SwiftDataStore
    ///   pushes `exerciseID` into the fetch predicate; ~0.5 s at 50k
    ///   SetRecords for one exercise's full history, measured by
    ///   `StatsQueryBenchmarkTests`) — never `loggedSetSlices(exerciseID:
    ///   nil, ...)` filtered in Swift afterward, which would reintroduce
    ///   the unbounded all-exercise scan this API exists to avoid.
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
            if quantizedEstimate(point.estimatedOneRepMax) > quantizedEstimate(runningEstimate) {
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
