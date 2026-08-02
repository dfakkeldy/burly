// SPDX-License-Identifier: GPL-3.0-or-later
// Placeholder destination for §2's Start and "Empty session" actions.
// Session flow screens (start, logging) are a later task -- this exists so
// the routine list's navigation is real rather than a dead end.

import SwiftUI

struct SessionStartStubView: View {
    let route: HomeRoute

    var body: some View {
        // Scroll-capable so large Dynamic Type can't clip content
        // unreachably (m2-01 review finding 6.1).
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    // Decorative -- the heading right below it already says
                    // the same thing in words (m2-01 review finding 6.3).
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    // Stable identifier for UI tests (m2-01 review finding
                    // 6.2): the composed sentence (e.g. "Starting Leg Day")
                    // is not itself the contract, so selection goes through
                    // this identifier rather than the literal copy.
                    .accessibilityIdentifier("sessionStartStubView.heading")
                Text("Session logging is coming in a later update.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private var heading: String {
        switch route {
        case .start(_, let routineName):
            "Starting \(routineName)"
        case .emptySession:
            "Empty session"
        }
    }
}

#Preview {
    SessionStartStubView(route: .emptySession)
}
