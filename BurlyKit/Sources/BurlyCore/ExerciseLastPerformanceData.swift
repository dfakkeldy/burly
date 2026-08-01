// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ExerciseLastPerformanceData
//
// Value-type mirror of the SwiftData `ExerciseLastPerformance` entity (spec
// §1) — the watch-store-only digest entity. Written only from phone-pushed
// digests (application context, §5) and read by the watch logging screen's
// ghost row (§2) to answer "what did I do last time." The phone never
// stores this entity; it derives digests from full history at push time.
// See the module doc in BurlyCore.swift for the naming scheme this file
// follows.
//
// Imports Foundation for `UUID` (exerciseID) and `Date` (performedAt) only.
import Foundation

public struct ExerciseLastPerformanceData: Sendable, Equatable, Hashable, Codable {
    public var exerciseID: UUID
    public var performedAt: Date

    /// Spec's embedded `[SetSnapshot]` (`@Attribute(.codable)` value
    /// structs) — the numbers the ghost row renders per set index.
    public var sets: [SetSnapshot]

    public init(exerciseID: UUID, performedAt: Date, sets: [SetSnapshot]) {
        self.exerciseID = exerciseID
        self.performedAt = performedAt
        self.sets = sets
    }
}
