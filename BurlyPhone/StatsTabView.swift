// SPDX-License-Identifier: GPL-3.0-or-later
// Stats tab (spec m5-01): a real, store-backed empty state on zero stats
// (no logged sessions yet), and a minimal honest summary once workouts
// exist -- the stats charts are a later task, so the non-empty state is a
// count and a plain statement, never a chart.

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
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load stats",
                message: message,
                identifierPrefix: "statsTab",
                onRetry: { viewModel.load() }
            )
        case .loaded:
            if viewModel.loggedSessions.isEmpty {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: "No stats yet",
                    message: "Complete a workout and your stats will start appearing here.",
                    identifierPrefix: "statsTab"
                )
            } else {
                List {
                    Section {
                        LabeledContent("Workouts logged", value: "\(viewModel.loggedSessions.count)")
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
