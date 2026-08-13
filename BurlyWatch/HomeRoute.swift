// SPDX-License-Identifier: GPL-3.0-or-later
// Navigation routes for the watch home shell (spec §2). Start and the
// list-end "Empty session" action push these values; ContentView resolves
// them to a real session (SessionEntryView, m2-03).

import Foundation

enum HomeRoute: Hashable {
    /// §2 Start, tapped on a routine row.
    case start(routineID: UUID, routineName: String)
    /// §2's list-end "Empty session" secondary action.
    case emptySession
    /// §2/§3 Resume (m2-06): reattaches to the in-flight session
    /// `ResumeSessionView` already found via `resumableActiveSession()`.
    /// Carries the id, not the `ActiveSession` itself -- `SessionEntryView`
    /// re-fetches it fresh via `store.activeSession(id:)`, the same
    /// "carry ids through routes, resolve the real data at the
    /// destination" shape `.start(routineID:)` already uses, and the only
    /// shape available at all: `ActiveSession` isn't `Hashable`, and a
    /// `HomeRoute` case has to be.
    ///
    /// `enterSummary` distinguishes Resume's two actions: `false` for
    /// "Resume workout" (the ordinary pager, sets and rest timer intact),
    /// `true` for "Not now" (§2: "Declining resume = normal end-workout
    /// summary path" -- straight to Finish/Keep going/Discard).
    case resume(sessionID: UUID, enterSummary: Bool)
}
