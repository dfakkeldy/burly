// SPDX-License-Identifier: GPL-3.0-or-later
// iPhone app shell root (spec m5-01): shows the one-time welcome while the
// user hasn't chosen how to start, then hosts the four-tab shell.
//
// Welcome is decided FIRST, from the persisted flag alone — the store is
// never opened to answer it (m5-01 review finding 1). A transient store
// failure on a genuine first launch therefore cannot gate the welcome, and
// the user reaches a choice before storage is even touched.
//
// The store is owned by `PhoneAppModel` (one store per process, shared with
// sync — see that file), never by a view initializer, which SwiftUI is free
// to re-run. A returning user's store is already open from launch; on a
// first launch the shell's `.task` resolves it when that branch appears
// (welcome dismissed or skipped), and `body` only ever switches on the
// already-resolved `storeResult`. A failed resolution shows
// `StoreUnavailableView` with a Retry that re-attempts construction.

import SwiftUI
import BurlyPersistence

@MainActor
struct ContentView: View {
    let model: PhoneAppModel
    @State private var showWelcome: Bool
    /// Set when the welcome's "Import from Hevy" dismissed it (m7-02): the
    /// shell opens the import screen over the tabs once the store resolves,
    /// so the import and the tabs share the one store instance.
    @State private var importOnShellEntry = false

    init(model: PhoneAppModel) {
        self.model = model
        // The reset seam must run before the flag is first read, so the
        // relaunch test starts from the genuine uncompleted state (m5-01
        // review finding 5). No-op on real launches.
        WelcomeState.resetIfRequested()
        _showWelcome = State(initialValue: !WelcomeState.isCompleted())
    }

    var body: some View {
        if showWelcome {
            WelcomeView(
                onStartFresh: {
                    showWelcome = false
                },
                onImportFromHevy: {
                    importOnShellEntry = true
                    showWelcome = false
                }
            )
        } else {
            shellContent
                // Resolve the store when the tab shell is entered — this
                // branch appears only once the welcome is dismissed or
                // skipped (finding 1). The guard makes re-entry a no-op;
                // Retry re-runs `resolveStore()` on demand.
                .task {
                    guard model.storeResult == nil else { return }
                    model.resolveStore()
                }
        }
    }

    @ViewBuilder
    private var shellContent: some View {
        if let storeResult = model.storeResult {
            switch storeResult {
            case .success(let store):
                MainTabView(store: store, sync: model.sync, presentsHevyImportOnAppear: importOnShellEntry)
            case .failure(let error):
                StoreUnavailableView(message: String(describing: error)) {
                    model.resolveStore()
                }
            }
        } else {
            ProgressView()
        }
    }
}
