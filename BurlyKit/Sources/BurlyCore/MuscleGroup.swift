// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — MuscleGroup
//
// The frozen 12-value muscle-tag taxonomy (spec burly-spec.md §1, §9).
// Exercises multi-tag against this enum (`[MuscleGroup]` on ExerciseData)
// to drive the muscle-split stat (§7, fractional attribution across tags)
// and the catalog seed's tag browser (§9).
//
// STABILITY PROMISE: rawValues are lowerCamelCase strings and are wire
// format — they appear in the catalog seed JSON (§9) and any future sync
// DTO (§5). Once shipped, a rawValue is never renamed, and this is a
// closed set of exactly 12 cases; adding a 13th (or renaming one) requires
// its own DECISIONS.md entry, since §1 is FROZEN as of 2026-08-01.
//
// No Foundation import: a plain String-backed enum needs nothing from any
// framework.
public enum MuscleGroup: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case chest
    case upperBack
    case lats
    case shoulders
    case biceps
    case triceps
    case forearms
    case quads
    case hamstrings
    case glutes
    case calves
    case core
}
