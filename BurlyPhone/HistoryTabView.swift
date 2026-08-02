// SPDX-License-Identifier: GPL-3.0-or-later
// History tab (spec m5-01, the default tab): a real, store-backed empty
// state on zero history, and a minimal list of logged sessions once any
// exist -- the full history UI is a later task, but "no history" must be
// the store's answer, not a hardcoded screen.

import SwiftUI

@MainActor
struct HistoryTabView: View {
    let viewModel: PhoneHomeViewModel

    var body: some View {
        content
            .navigationTitle("History")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load history",
                message: message,
                identifierPrefix: "historyTab",
                onRetry: { viewModel.load() }
            )
        case .loaded:
            if viewModel.loggedSessions.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No history yet",
                    message: "Workouts you finish will show up here, starting with your first session.",
                    identifierPrefix: "historyTab"
                )
            } else {
                List(viewModel.loggedSessions) { session in
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
