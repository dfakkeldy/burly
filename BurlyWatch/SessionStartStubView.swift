// SPDX-License-Identifier: GPL-3.0-or-later
// Placeholder destination for §2's Start and "Empty session" actions.
// Session flow screens (start, logging) are a later task -- this exists so
// the routine list's navigation is real rather than a dead end.

import SwiftUI

struct SessionStartStubView: View {
    let route: HomeRoute

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(heading)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Session logging is coming in a later update.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
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
