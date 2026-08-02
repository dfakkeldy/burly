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
// Callers own the range filter (3 m / 6 m / 1 y / all, §7) and the
// exercise filter — both are a `BurlyStore.loggedSetSlices` query concern,
// not this file's. Every function here operates on whatever slices it is
// given, in any order, and does its own chronological sort.
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
    /// depending on `kind`.
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
            .sorted { lhs, rhs in
                lhs.date == rhs.date
                    ? lhs.sessionID.uuidString < rhs.sessionID.uuidString
                    : lhs.date < rhs.date
            }
    }

    /// Walks `points` chronologically and emits one `PersonalRecord` per
    /// session that **strictly** beats the running maximum on either
    /// series so far — a tie is not a new record. A single session can set
    /// both kinds; each is reported once, in `points`' order.
    ///
    /// - Parameter points: must already be chronological — `sessionPoints`
    ///   returns them that way; this does not re-sort.
    public static func personalRecords(from points: [ExerciseSessionPoint]) -> [PersonalRecord] {
        var runningTopWeightKg = -Double.infinity
        var runningEstimate = -Double.infinity
        var records: [PersonalRecord] = []

        for point in points {
            if point.topWeight.kg > runningTopWeightKg {
                runningTopWeightKg = point.topWeight.kg
                records.append(
                    PersonalRecord(sessionID: point.sessionID, date: point.date, kind: .topWeight, value: point.topWeight.kg)
                )
            }
            if point.estimatedOneRepMax > runningEstimate {
                runningEstimate = point.estimatedOneRepMax
                records.append(
                    PersonalRecord(sessionID: point.sessionID, date: point.date, kind: .estimatedOneRepMax, value: point.estimatedOneRepMax)
                )
            }
        }
        return records
    }
}
