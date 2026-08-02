// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 watch home: routine list, one Start row per routine plus the
// list-end "Empty session" secondary action. Whole-row NavigationLinks keep
// tap targets large and glanceable (the hands-busy test).

import SwiftUI

struct RoutineListView: View {
    let rows: [WatchHomeViewModel.RoutineRow]

    var body: some View {
        List {
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
