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
private struct RootView: View {
    var body: some View {
        switch Self.resolveStore() {
        case .success(let store):
            ContentView(store: store)
        case .failure(let error):
            StoreUnavailableView(message: String(describing: error))
        }
    }

    private static func resolveStore() -> Result<BurlyStore, Error> {
        #if DEBUG
        if let seeded = WatchDemoSeed.requestedStore() {
            return .success(seeded)
        }
        #endif
        do {
            return .success(try SwiftDataStore.watch())
        } catch {
            return .failure(error)
        }
    }
}
