// SPDX-License-Identifier: GPL-3.0-or-later
// The four-tab iPhone shell (spec m5-01): History (default) / Routines /
// Stats / Settings. Every tab renders its real state from the shared
// PhoneHomeViewModel, which loads the phone store once on appear — a fresh
// install therefore shows honest, store-backed empty states, never a
// hardcoded "always empty."
//
// The shell's own load is deliberately bounded (m5-01 review finding 3):
// existence/count only (`hasRoutines` / `loggedSessionCount`). The tabs
// that render rows fetch them from the store's existing surfaces when that
// tab is shown, never at shell appearance.
//
// Foregrounding reloads the snapshot (m5-01 review finding 2, matching the
// accepted watch-shell behavior — the watch re-runs its `load()` when
// `scenePhase` becomes `.active`): the bounded counts for both domains,
// plus the rows of whichever tab is currently visible. Query failures keep
// their visible Retry in each tab (EmptyStateView).

import SwiftUI
import BurlyPersistence

@MainActor
struct MainTabView: View {
    @State private var viewModel: PhoneHomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: ShellTab = .history

    /// The four spec tabs, tracked so a foreground reload can refresh the
    /// visible tab's rows (finding 2) without loading a hidden tab's.
    enum ShellTab: Hashable {
        case history, routines, stats, settings
    }

    init(store: BurlyStore) {
        _viewModel = State(initialValue: PhoneHomeViewModel(store: store))
    }

    var body: some View {
        TabView(selection: $selection) {
            HistoryTabView(viewModel: viewModel)
                .tag(ShellTab.history)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .accessibilityIdentifier("tab.history")
                }
            RoutinesTabView(viewModel: viewModel)
                .tag(ShellTab.routines)
                .tabItem {
                    Label("Routines", systemImage: "list.bullet.rectangle")
                        .accessibilityIdentifier("tab.routines")
                }
            StatsTabView(viewModel: viewModel)
                .tag(ShellTab.stats)
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                        .accessibilityIdentifier("tab.stats")
                }
            SettingsView()
                .tag(ShellTab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                        .accessibilityIdentifier("tab.settings")
                }
        }
        // Bounded shell snapshot (existence/count only — finding 3), fired
        // when the tabs appear. Rows load in each tab's own `.task`.
        .task { viewModel.load() }
        // Shell-level reload mechanics (m5-01 review finding 2, mirroring
        // the watch shell's m2-01 finding 4.1): a relaunch from the
        // background is the one lifecycle signal this shell can already
        // observe without the sync transport (M4), which is what will
        // eventually invalidate state on its own. No timers, no polling —
        // just re-running the same loads the initial `.task` runs, plus the
        // visible tab's rows so a background writer's changes show up.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.load()
            switch selection {
            case .history:
                viewModel.loadSessionsForDisplay()
            case .routines:
                viewModel.loadRoutinesForDisplay()
            case .stats, .settings:
                break
            }
        }
    }
}

#Preview {
    MainTabView(store: try! SwiftDataStore.phone(at: .inMemory))
}
