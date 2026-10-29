// SPDX-License-Identifier: GPL-3.0-or-later
// The one-time first-launch welcome (spec m5-01, §9): a single screen
// offering "Import from Hevy" or "Start fresh".
//
// Either button completes the welcome -- the spec says relaunches skip it
// without qualification -- and both hand the user to the tab shell. Import
// additionally asks the shell to open the Hevy import screen over the tabs
// (m7-02), so finishing or cancelling the import lands on History, the
// default tab, never back on a welcome that has already been answered. The
// import screen needs the store, and the store is resolved only once the
// shell is entered (ContentView, m5-01 review finding 1); presenting it from
// the shell keeps one store instance behind both the import and the tabs.

import SwiftUI

struct WelcomeView: View {
    /// Called when the user picks "Start fresh": the shell drops the welcome
    /// and shows the tab shell.
    let onStartFresh: () -> Void
    /// Called when the user picks "Import from Hevy": the shell drops the
    /// welcome and presents the import screen over the tab shell.
    let onImportFromHevy: () -> Void

    var body: some View {
        // Scroll-capable root (m5-01 review finding 7): on a short iPhone at
        // an accessibility text size, the large heading, the wrapped
        // message, and two growing buttons can exceed the viewport — a
        // ScrollView keeps both first-launch actions reachable at every
        // supported Dynamic Type size.
        ScrollView {
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
                        onImportFromHevy()
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
        }
    }
}

#Preview {
    WelcomeView(onStartFresh: {}, onImportFromHevy: {})
}
