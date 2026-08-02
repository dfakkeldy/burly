// SPDX-License-Identifier: GPL-3.0-or-later
// Routines tab (spec m5-01): a real, store-backed empty state on zero
// routines, and a minimal list of routine names once any exist -- the
// routine editor is a later task, but "no routines" must be the store's
// answer, not a hardcoded screen.

import SwiftUI

@MainActor
struct RoutinesTabView: View {
    let viewModel: PhoneHomeViewModel

    var body: some View {
        content
            .navigationTitle("Routines")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load routines",
                message: message,
                identifierPrefix: "routinesTab",
                onRetry: { viewModel.load() }
            )
        case .loaded:
            if viewModel.routines.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: "No routines yet",
                    message: "Routines you create will show up here. Building routines is coming in a later update.",
                    identifierPrefix: "routinesTab"
                )
            } else {
                List(viewModel.routines) { routine in
                    Text(routine.name)
                        .font(.headline)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("routinesTab.routineRow.\(routine.name)")
                }
            }
        }
    }
}

#Preview {
    RoutinesTabView(viewModel: .previewLoaded)
}
