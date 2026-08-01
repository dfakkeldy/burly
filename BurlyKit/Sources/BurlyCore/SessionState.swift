// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionState
//
// A session's lifecycle state (spec §1, §2). `.active` sessions are
// mutable and live on the watch; "Finish" (§2) transitions to `.logged`,
// which is immutable on the watch — only the phone edits a `.logged`
// session afterward (§6, single-writer rule in the architecture doc).
//
// No Foundation import needed.
public enum SessionState: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case active
    case logged
}
