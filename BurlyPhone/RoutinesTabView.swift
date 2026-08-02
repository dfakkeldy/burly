// SPDX-License-Identifier: GPL-3.0-or-later
// Routines tab (spec m5-01): a real, store-backed empty state on zero
// routines, and a minimal list of routine names once any exist -- the
// routine editor is a later task, but "no routines" must be the store's
// answer, not a hardcoded screen.
//
// Rows load only when this tab is shown (m5-01 review finding 3): the
// shell's appearance load answers existence with the bounded
// `hasRoutines()`; the actual routine rows come from the store's §9 surface
// in this tab's `.task`. Failures render in this tab's own domain state
// (finding 4) with a visible Retry.
//
// Row identifiers are keyed by `routine.id`, never by name (m5-01 review
// finding 8): names are mutable and non-unique, so XCUITest cannot select a
// row by one — the id is the stable handle, exactly as History keys session
// rows by `session.id`.

import SwiftUI

@MainActor
struct RoutinesTabView: View {
    let viewModel: PhoneHomeViewModel

    var body: some View {
        content
            .navigationTitle("Routines")
            // Rows only when the tab is shown (finding 3).
            .task { viewModel.loadRoutinesForDisplay() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.routinesState {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load routines",
                message: message,
                identifierPrefix: "routinesTab",
                onRetry: { viewModel.loadRoutinesForDisplay() }
            )
        case .loaded:
            if !viewModel.hasRoutines {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: "No routines yet",
                    message: "Routines you create will show up here. Building routines is coming in a later update.",
                    identifierPrefix: "routinesTab"
                )
            } else if viewModel.routineRows.isEmpty {
                // Existence says routines exist but the rows (this tab's
                // lazy load) haven't landed yet.
                ProgressView()
            } else {
                List(viewModel.routineRows) { routine in
                    Text(routine.name)
                        .font(.headline)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("routinesTab.routineRow.\(routine.id.uuidString)")
                }
            }
        }
    }
}

#Preview {
    RoutinesTabView(viewModel: .previewLoaded)
}
