// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SetSnapshot
//
// Embedded value struct for `ExerciseLastPerformance.sets` (spec §1, watch
// store only — `@Attribute(.codable)`). Deliberately minimal: just the
// three numbers the logging screen's ghost row needs (§2) to answer "what
// did I do last time" per set index. No `id`, no `Date` — it's a snapshot,
// not an entity; it never needs identity, and `ExerciseLastPerformance
// .performedAt` already covers timing for the whole digest entry.
//
// No Foundation import: nothing here needs UUID, Date, or Measurement.
public struct SetSnapshot: Sendable, Equatable, Hashable, Codable {
    /// Canonical stored unit, same guarantee as SetRecordData.weightKg:
    /// only settable through `Weight`.
    public private(set) var weightKg: Double
    public var reps: Int
    public var isWarmup: Bool

    public init(weight: Weight, reps: Int, isWarmup: Bool = false) {
        self.weightKg = weight.kg
        self.reps = reps
        self.isWarmup = isWarmup
    }

    public var weight: Weight {
        Weight(kg: weightKg)
    }
}
