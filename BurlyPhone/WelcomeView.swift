// SPDX-License-Identifier: GPL-3.0-or-later
// The one-time first-launch welcome (spec m5-01): a single screen offering
// "Import from Hevy" or "Start fresh". Import pushes the clearly-labeled
// placeholder screen (the real import UI is a later task); Start fresh
// dismisses the welcome into the tab shell.
//
// Either button completes the welcome -- the spec says relaunches skip it
// without qualification -- but only Start fresh switches the shell to the
// tabs right now; the Import path stays inside this NavigationStack so Back
// behaves normally within the session.

import SwiftUI

/// The destinations reachable from the welcome screen.
enum WelcomeRoute: Hashable {
    /// The clearly-labeled placeholder for the (later-task) Hevy import UI.
    case importHevy
}

struct WelcomeView: View {
    /// Called when the user picks "Start fresh": the shell drops the welcome
    /// and shows the tab shell.
    let onStartFresh: () -> Void

    @State private var path: [WelcomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 48))
                    // Decorative -- the heading right below says the same
                    // thing in words.
                    .accessibilityHidden(true)
                Text("Welcome to Burly")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("welcomeView.heading")
                Text("A watch-first lifting tracker. Choose how you'd like to start.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("welcomeView.message")

                VStack(spacing: 10) {
                    Button {
                        WelcomeState.markCompleted()
                        path.append(.importHevy)
                    } label: {
                        Label("Import from Hevy", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("welcomeView.importButton")

                    Button {
                        WelcomeState.markCompleted()
                        onStartFresh()
                    } label: {
                        Label("Start fresh", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("welcomeView.startFreshButton")
                }
                .padding(.top, 8)
            }
            .padding()
            .navigationDestination(for: WelcomeRoute.self) { route in
                switch route {
                case .importHevy:
                    ImportPlaceholderView()
                }
            }
        }
    }
}

#Preview {
    WelcomeView(onStartFresh: {})
}
