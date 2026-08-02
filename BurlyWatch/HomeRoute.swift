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
}
