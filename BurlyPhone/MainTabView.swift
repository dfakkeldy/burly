// SPDX-License-Identifier: GPL-3.0-or-later
// The four-tab iPhone shell (spec m5-01): History (default) / Routines /
// Stats / Settings. Every tab renders its real state from the shared
// PhoneHomeViewModel, which loads the phone store once on appear -- a fresh
// install therefore shows honest, store-backed empty states, never a
// hardcoded "always empty."

import SwiftUI
import BurlyPersistence

@MainActor
struct MainTabView: View {
    @State private var viewModel: PhoneHomeViewModel

    init(store: BurlyStore) {
        _viewModel = State(initialValue: PhoneHomeViewModel(store: store))
    }

    var body: some View {
        TabView {
            HistoryTabView(viewModel: viewModel)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .accessibilityIdentifier("tab.history")
                }
            RoutinesTabView(viewModel: viewModel)
                .tabItem {
                    Label("Routines", systemImage: "list.bullet.rectangle")
                        .accessibilityIdentifier("tab.routines")
                }
            StatsTabView(viewModel: viewModel)
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                        .accessibilityIdentifier("tab.stats")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                        .accessibilityIdentifier("tab.settings")
                }
        }
        // One store read for the whole shell, fired when the tabs appear.
        .task { viewModel.load() }
    }
}

#Preview {
    MainTabView(store: try! SwiftDataStore.phone(at: .inMemory))
}
