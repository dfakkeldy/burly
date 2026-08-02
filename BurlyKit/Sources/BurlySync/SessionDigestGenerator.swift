// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import BurlyCore

/// Derives the complete, latest-per-exercise digest from phone history.
/// Absence is meaningful: an exercise omitted here has no logged set in the
/// supplied history, so callers must always derive from the full history at
/// publication time rather than incrementally accumulating old entries.
public enum SessionDigestGenerator {
    public static func lastPerformance(from history: [SessionData]) -> [ExerciseLastPerformanceData] {
        var latest: [UUID: (performedAt: Date, sets: [SetSnapshot])] = [:]
        for session in history where session.state == .logged {
            for item in session.items {
                guard let exerciseID = item.exerciseID, !item.sets.isEmpty else { continue }
                let performedAt = item.sets.map(\.completedAt).max() ?? session.endedAt ?? session.startedAt
                let snapshots = item.sets
                    .sorted { $0.order < $1.order }
                    .map { SetSnapshot(weight: $0.weight, reps: $0.reps, isWarmup: $0.isWarmup) }
                if latest[exerciseID].map({ performedAt > $0.performedAt }) ?? true {
                    latest[exerciseID] = (performedAt, snapshots)
                }
            }
        }
        return latest.map { id, value in
            ExerciseLastPerformanceData(exerciseID: id, performedAt: value.performedAt, sets: value.sets)
        }
        .sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
    }
}
