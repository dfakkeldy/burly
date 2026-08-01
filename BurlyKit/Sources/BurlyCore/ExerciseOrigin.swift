// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — ExerciseOrigin
//
// Where an Exercise entered the catalog (spec §1). `.curated` ships with
// the seed (§9); `.custom` is user-authored (including watch
// needsNaming placeholders before they're named); `.hevyImport` is created
// during CSV import for an unmatched name (§8). Drives nothing beyond
// provenance display today, but is never dropped once a SetRecord exists
// against the exercise (archive-not-delete, §1).
//
// No Foundation import needed.
public enum ExerciseOrigin: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case curated
    case custom
    case hevyImport
}
