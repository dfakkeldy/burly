// SPDX-License-Identifier: GPL-3.0-or-later
// Navigation stubs for the watch home shell (spec §2). Session flow screens
// (start, logging) are later tasks -- these routes exist only so Start and
// the list-end "Empty session" action push to something real instead of
// being dead taps.

import Foundation

enum HomeRoute: Hashable {
    /// §2 Start, tapped on a routine row.
    case start(routineID: UUID, routineName: String)
    /// §2's list-end "Empty session" secondary action.
    case emptySession
}
