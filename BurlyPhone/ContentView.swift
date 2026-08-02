// SPDX-License-Identifier: GPL-3.0-or-later
// iPhone app shell root (spec m5-01): resolves the phone store exactly once
// per launch, shows the one-time welcome while the user hasn't chosen how to
// start, then hosts the four-tab shell.
//
// The store is resolved once, in `init`, and held in `@State` (m2-01 review
// finding 3.1 applied to the phone) -- not recomputed from `body`, which
// SwiftUI is free to re-evaluate at any time. A body-computed
// `switch Self.resolveStore()` would open a fresh `ModelContainer` (or reach
// a different transient result) on every re-evaluation, coupling store
// lifetime to rendering instead of to this view's place in the scene.

import SwiftUI
import BurlyPersistence

@MainActor
struct ContentView: View {
    @State private var storeResult: Result<BurlyStore, Error>
    @State private var showWelcome: Bool

    init() {
        _storeResult = State(initialValue: Self.resolveStore())
        _showWelcome = State(initialValue: !WelcomeState.isCompleted())
    }

    var body: some View {
        switch storeResult {
        case .success(let store):
            if showWelcome {
                WelcomeView(onStartFresh: {
                    showWelcome = false
                })
            } else {
                MainTabView(store: store)
            }
        case .failure(let error):
            StoreUnavailableView(message: String(describing: error))
        }
    }

    private static func resolveStore() -> Result<BurlyStore, Error> {
        do {
            return .success(try SwiftDataStore.phone())
        } catch {
            return .failure(error)
        }
    }
}
