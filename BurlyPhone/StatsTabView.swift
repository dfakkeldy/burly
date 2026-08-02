// SPDX-License-Identifier: GPL-3.0-or-later
// Stats tab (spec m5-01): a real, store-backed empty state on zero stats
// (no logged sessions yet), and a minimal honest summary once workouts
// exist -- the stats charts are a later task, so the non-empty state is a
// count and a plain statement, never a chart.
//
// The count is the bounded `loggedSessionCount()` scalar (m5-01 review
// finding 3): Stats never needs the session graph, so it never asks for
// it -- the shell's appearance load already provides the scalar, and this
// tab renders from the sessions domain state (finding 4) with a visible
// Retry.

import SwiftUI

@MainActor
struct StatsTabView: View {
    let viewModel: PhoneHomeViewModel

    var body: some View {
        content
            .navigationTitle("Stats")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.sessionsState {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load stats",
                message: message,
                identifierPrefix: "statsTab",
                onRetry: { viewModel.loadSessions() }
            )
        case .loaded:
            if viewModel.loggedSessionCount == 0 {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: "No stats yet",
                    message: "Complete a workout and your stats will start appearing here.",
                    identifierPrefix: "statsTab"
                )
            } else {
                List {
                    Section {
                        LabeledContent("Workouts logged", value: "\\(viewModel.loggedSessionCount)")
                            .accessibilityIdentifier("statsTab.workoutCountRow")
                    } footer: {
                        Text("Detailed stats charts are coming in a later update.")
                    }
                }
            }
        }
    }
}

#Preview {
    StatsTabView(viewModel: .previewLoaded)
}
