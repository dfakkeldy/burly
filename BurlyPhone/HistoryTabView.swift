// SPDX-License-Identifier: GPL-3.0-or-later
// History tab (spec m5-01, the default tab): a real, store-backed empty
// state on zero history, and a minimal list of logged sessions once any
// exist -- the full history UI is a later task, but "no history" must be
// the store's answer, not a hardcoded screen.
//
// Rows load only when this tab is shown (m5-01 review finding 3): the
// shell's appearance load answers existence with the bounded
// `loggedSessionCount()`; the actual session rows come from the store's §6
// surface in this tab's `.task`, so a long-time user's history graph is
// never hydrated just to draw the shell. Failures render in this tab's own
// domain state (finding 4) with a visible Retry.

import SwiftUI

@MainActor
struct HistoryTabView: View {
    let viewModel: PhoneHomeViewModel

    var body: some View {
        content
            .navigationTitle("History")
            // Rows only when the tab is shown (finding 3).
            .task { viewModel.loadSessionsForDisplay() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.sessionsState {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load history",
                message: message,
                identifierPrefix: "historyTab",
                onRetry: { viewModel.loadSessionsForDisplay() }
            )
        case .loaded:
            if viewModel.loggedSessionCount == 0 {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No history yet",
                    message: "Workouts you finish will show up here, starting with your first session.",
                    identifierPrefix: "historyTab"
                )
            } else if viewModel.sessionRows.isEmpty {
                // Count says history exists but the rows (this tab's lazy
                // load) haven't landed yet.
                ProgressView()
            } else {
                List(viewModel.sessionRows) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.routineName ?? "Workout")
                            .font(.headline)
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("historyTab.sessionRow.\(session.id.uuidString)")
                }
            }
        }
    }
}

#Preview {
    HistoryTabView(viewModel: .previewLoaded)
}
