// SPDX-License-Identifier: GPL-3.0-or-later
// Watch app shell root (spec §2 home, §5 fresh install). Switches between
// the routine list, the "waiting for iPhone" state, and a store-failure
// fallback, then hosts the §2 navigation stubs (Start, "Empty session").

import SwiftUI
import BurlyPersistence

struct ContentView: View {
    @State private var viewModel: WatchHomeViewModel

    init(store: BurlyStore) {
        _viewModel = State(initialValue: WatchHomeViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: HomeRoute.self) { route in
                    SessionStartStubView(route: route)
                }
        }
        .task { viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .waitingForPhone:
            WaitingForPhoneView()
        case .loaded(let rows):
            RoutineListView(rows: rows)
        case .failed(let message):
            StoreUnavailableView(message: message)
        }
    }
}

#Preview {
    ContentView(store: try! SwiftDataStore(kind: .watch, at: .inMemory))
}
