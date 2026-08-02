// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BurlyPersistence

@main
struct BurlyWatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Resolves the watch store for this launch before handing off to
/// ContentView. A real device launch always uses the on-device default
/// store, which starts empty until the (not yet built) sync layer delivers
/// a snapshot -- the real §5 "waiting for iPhone" case. BurlyWatchUITests
/// requests an isolated in-memory scenario instead; see WatchDemoSeed.swift.
///
/// The store is resolved exactly once, in `init`, and held in `@State`
/// (m2-01 review finding 3.1) -- not recomputed from `body`, which SwiftUI
/// is free to re-evaluate at any time. A body-computed `switch
/// Self.resolveStore()` would open a fresh `ModelContainer` (or reach a
/// different transient result) on every re-evaluation, coupling store
/// lifetime to rendering instead of to this view's place in the scene.
@MainActor
private struct RootView: View {
    @State private var storeResult: Result<BurlyStore, Error>

    init() {
        _storeResult = State(initialValue: Self.resolveStore())
    }

    var body: some View {
        switch storeResult {
        case .success(let store):
            ContentView(store: store)
        case .failure(let error):
            StoreUnavailableView(message: String(describing: error))
        }
    }

    private static func resolveStore() -> Result<BurlyStore, Error> {
        #if DEBUG
        // Once a scenario is recognized, WatchDemoSeed fails closed: its
        // Result is used as-is, success or failure, and never falls through
        // to the on-device store below (m2-01 review finding 2.1).
        if let requested = WatchDemoSeed.requestedStore() {
            return requested
        }
        #endif
        do {
            return .success(try SwiftDataStore.watch())
        } catch {
            return .failure(error)
        }
    }
}
