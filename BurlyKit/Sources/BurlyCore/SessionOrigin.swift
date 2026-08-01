// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionOrigin
//
// How a Session came to exist (spec §1). `.live` sessions are logged from
// the watch in real time (the only origination path in v1, per the
// architecture doc); `.hevyImport` sessions are created by CSV import
// (§8) and never get their own HKWorkout (Hevy already wrote it).
//
// No Foundation import needed.
public enum SessionOrigin: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case live
    case hevyImport
}
