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
                        Text(row.lastDoneText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            NavigationLink(value: HomeRoute.emptySession) {
                Label("Empty session", systemImage: "plus.circle")
            }
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
