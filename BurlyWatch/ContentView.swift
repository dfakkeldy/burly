// SPDX-License-Identifier: GPL-3.0-or-later
// Watch app shell root (spec §2 home, §5 fresh install). Switches between
// the routine list, the "waiting for iPhone" state, and a store-failure
// fallback, then routes Start / "Empty session" (§2) to the real session
// flow via SessionEntryView (m2-03).

import SwiftUI
import BurlyPersistence
import BurlyWatchSyncRuntime

@MainActor
struct ContentView: View {
    @State private var viewModel: WatchHomeViewModel
    private let store: BurlyStore
    /// `nil` in UI-test scenarios and previews (see WatchAppModel).
    private let sync: WatchSyncHost?
    @Environment(\.scenePhase) private var scenePhase

    init(store: BurlyStore, sync: WatchSyncHost? = nil) {
        self.store = store
        self.sync = sync
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
        // Sync invalidates the shell on its own (m4-06): every applied
        // snapshot (routines arrive, §5's "waiting for iPhone" unlocks) or
        // digest (acked sessions pruned, "last done" text) bumps this.
        .onChange(of: sync?.workingSetGeneration) { viewModel.load() }
        // Shell-level reload mechanics (m2-01 review finding 4.1), plus §5's
        // outbox retry "on every app activation". No timers, no polling --
        // just re-running the same `load()` the initial `.task` runs.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            sync?.appDidBecomeActive()
            viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
        case .waitingForPhone:
            WaitingForPhoneView(needsAppUpdate: sync?.heldSchemaVersion != nil)
        case .resumable(let preview):
            // §2 Resume gate (m2-06): takes priority over the routine list
            // itself -- see `WatchHomeViewModel`'s doc. Reload on
            // reappearance for the same reason `.loaded` does below:
            // resolving the conflict from `ResumeSessionView`'s own
            // Finish/Discard (the decline path) pops back to this same
            // `content` switch, and only a fresh `load()` notices the
            // session is no longer active and flips to the routine list.
            ResumeSessionView(preview: preview)
                .onAppear { viewModel.load() }
        case .unreadableSession(let sessionID):
            // m2-06 review finding 2.1: a targeted, self-clearing recovery
            // -- see `WatchHomeViewModel`'s doc -- never the Retry-only
            // `.failed` state below, which would just re-read the same
            // undecodable journal forever.
            UnreadableSessionView {
                viewModel.discardUnreadableSession(sessionID)
            }
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
