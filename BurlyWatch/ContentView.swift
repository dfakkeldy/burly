// SPDX-License-Identifier: GPL-3.0-or-later
// Watch app shell root (spec §2 home, §5 fresh install). Switches between
// the routine list, the "waiting for iPhone" state, and a store-failure
// fallback, then routes Start / "Empty session" (§2) to the real session
// flow via SessionEntryView (m2-03).

import SwiftUI
import BurlyPersistence

@MainActor
struct ContentView: View {
    @State private var viewModel: WatchHomeViewModel
    private let store: BurlyStore
    @Environment(\.scenePhase) private var scenePhase

    init(store: BurlyStore) {
        self.store = store
        _viewModel = State(initialValue: WatchHomeViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: HomeRoute.self) { route in
                    SessionEntryView(route: route, store: store)
                }
        }
        .task { viewModel.load() }
        // Shell-level reload mechanics (m2-01 review finding 4.1): a
        // relaunch from the background is the one lifecycle signal this
        // shell can already observe without the sync transport (M4), which
        // is what will eventually invalidate state on its own. No timers,
        // no polling -- just re-running the same `load()` the initial
        // `.task` already runs.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .waitingForPhone:
            WaitingForPhoneView()
        case .loaded(let rows):
            // Reload on every reappearance (m2-03): finishing or discarding
            // a workout pops back here, and the "last done N days ago" text
            // on the routine that was just run needs to reflect it without
            // waiting for a scenePhase transition.
            RoutineListView(rows: rows)
                .onAppear { viewModel.load() }
        case .failed(let message):
            // A visible retry, not just a scenePhase-triggered one (m2-01
            // review finding 4.1): a transient failure shouldn't require
            // backgrounding and reopening the app to recover.
            StoreUnavailableView(message: message) { viewModel.load() }
        }
    }
}

#Preview {
    ContentView(store: try! SwiftDataStore(kind: .watch, at: .inMemory))
}
