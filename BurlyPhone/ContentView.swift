// SPDX-License-Identifier: GPL-3.0-or-later
// iPhone app shell root (spec m5-01): shows the one-time welcome while the
// user hasn't chosen how to start, then hosts the four-tab shell.
//
// Welcome is decided FIRST, from the persisted flag alone — the store is
// never opened to answer it (m5-01 review finding 1). A transient store
// failure on a genuine first launch therefore cannot gate the welcome, and
// the user reaches a choice before storage is even touched.
//
// The store is resolved lazily, when the tab shell is actually entered, and
// the result is held in `@State` — the lifetime-stable owner. The old eager
// factory in `init` coupled store lifetime to a SwiftUI view initializer,
// which SwiftUI is free to re-run; here the `.task` lives on the shell
// branch, so it fires exactly when that branch appears (welcome dismissed
// or skipped), and `body` only ever switches on the already-resolved
// `storeResult`. A failed resolution shows `StoreUnavailableView` with a
// Retry that re-attempts construction and replaces `storeResult`.

import SwiftUI
import BurlyPersistence

@MainActor
struct ContentView: View {
    @State private var storeResult: Result<BurlyStore, Error>?
    @State private var showWelcome: Bool

    init() {
        // The reset seam must run before the flag is first read, so the
        // relaunch test starts from the genuine uncompleted state (m5-01
        // review finding 5). No-op on real launches.
        WelcomeState.resetIfRequested()
        _showWelcome = State(initialValue: !WelcomeState.isCompleted())
    }

    var body: some View {
        if showWelcome {
            WelcomeView(onStartFresh: {
                showWelcome = false
            })
        } else {
            shellContent
                // Resolve the store when the tab shell is entered — this
                // branch appears only once the welcome is dismissed or
                // skipped (finding 1). The guard makes re-entry a no-op;
                // Retry re-runs `resolveStore()` on demand.
                .task {
                    guard storeResult == nil else { return }
                    resolveStore()
                }
        }
    }

    @ViewBuilder
    private var shellContent: some View {
        if let storeResult {
            switch storeResult {
            case .success(let store):
                MainTabView(store: store)
            case .failure(let error):
                StoreUnavailableView(message: String(describing: error)) {
                    resolveStore()
                }
            }
        } else {
            ProgressView()
        }
    }

    /// Builds the phone store exactly once per entry into the tab shell and
    /// stores the result in `@State` — never recomputed from `body`, which
    /// SwiftUI re-evaluates freely. The DEBUG branch consults
    /// `PhoneDemoSeed` first so UI tests get deterministic in-memory
    /// scenarios; a recognized scenario that fails to seed comes back as a
    /// `.failure` here and renders the unavailable view, never the
    /// on-device store (m5-01 review finding 6).
    private func resolveStore() {
        // Already resolved: keep the existing store. Retry reaches this
        // only with `.failure` (or `.success` from a race), so an existing
        // working store is never discarded and rebuilt.
        if case .success = storeResult { return }
        #if DEBUG
        if let seeded = PhoneDemoSeed.requestedStore() {
            storeResult = seeded
            return
        }
        #endif
        do {
            storeResult = .success(try SwiftDataStore.phone())
        } catch {
            storeResult = .failure(error)
        }
    }
}
