// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 watch home: routine list, one Start row per routine plus the
// list-end "Empty session" secondary action. Whole-row NavigationLinks keep
// tap targets large and glanceable (the hands-busy test).
//
// The list also shows once a snapshot with no routines arrived (a new user,
// or every routine archived): a hint to build one on iPhone, then "Empty
// session", which needs none. And while the watch holds an envelope from a
// newer Burly (§5: held, never partly read), a notice at the top says the
// routines below may be out of date until Burly on the watch is updated.

import SwiftUI
import BurlyWatchSyncRuntime

struct RoutineListView: View {
    let rows: [WatchHomeViewModel.RoutineRow]
    /// Written by `WatchSyncHost`; 0 when nothing is held.
    @AppStorage(WatchSyncHost.heldSchemaVersionDefaultsKey) private var heldSchemaVersion = 0

    var body: some View {
        List {
            if WatchSyncHost.needsAppUpdate(heldSchemaVersion: heldSchemaVersion) {
                Text("Your iPhone has a newer Burly. Update Burly on Apple Watch to get your latest routines.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routineList.updateNotice")
            }

            if rows.isEmpty {
                Text("No routines yet. Create one in Burly on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routineList.emptyHint")
            }

            ForEach(rows) { row in
                NavigationLink(value: HomeRoute.start(routineID: row.id, routineName: row.name)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.headline)
                            // A `staticTexts` query is the proven-reliable
                            // way to hit this row from BurlyWatchUITests
                            // (tapping it selects the whole NavigationLink);
                            // the identifier just decouples that selection
                            // from the row's exact rendered text (m2-01
                            // review finding 6.2).
                            .accessibilityIdentifier("routineRow.\(row.name).name")
                        Text(row.lastDoneText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            // Scoped by the routine's own name rather than
                            // its rendered wording (m2-01 review finding
                            // 6.2): relative-date phrasing like "3 days
                            // ago" isn't the contract, so tests select this
                            // row's last-done text without matching it.
                            .accessibilityIdentifier("routineRow.\(row.name).lastDone")
                    }
                    .padding(.vertical, 4)
                }
                // Stable per-row identifier (m2-01 review finding 6.2):
                // decouples row selection from the row's visible text, so a
                // copy/localization change can't break navigation tests.
                .accessibilityIdentifier("routineRow.\(row.name)")
            }

            NavigationLink(value: HomeRoute.emptySession) {
                Label("Empty session", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("emptySessionRow")
        }
        .navigationTitle("Burly")
    }
}

#Preview {
    NavigationStack {
        RoutineListView(rows: [
            WatchHomeViewModel.RoutineRow(id: UUID(), name: "Leg Day", lastDoneText: "Last done 3 days ago"),
            WatchHomeViewModel.RoutineRow(id: UUID(), name: "Push/Pull", lastDoneText: "Never done")
        ])
    }
}

#Preview("No routines yet") {
    NavigationStack {
        RoutineListView(rows: [])
    }
}
