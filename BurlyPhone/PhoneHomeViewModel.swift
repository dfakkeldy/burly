// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the iPhone shell's shared state from the phone store (spec m5-01):
// the History, Routines, and Stats tabs all render from this one load, so a
// launch reads the store once instead of once per tab.
//
// The reads are the store's own history-surface queries -- routines
// excluding archived (§9) and sessions(state: .logged) (§6 history surface;
// an `.active` workout is not history yet) -- so an empty result is a real
// "this phone has nothing yet" and a non-empty result renders rows, never a
// hardcoded empty state.

import Foundation
import BurlyCore
import BurlyPersistence
import Observation

@MainActor
@Observable
final class PhoneHomeViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var routines: [RoutineData] = []
    private(set) var loggedSessions: [SessionData] = []

    private let store: BurlyStore

    init(store: BurlyStore) {
        self.store = store
    }

    func load() {
        do {
            routines = try store.routines(includingArchived: false)
            loggedSessions = try store.sessions(state: .logged)
            state = .loaded
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

#if DEBUG
extension PhoneHomeViewModel {
    /// A loaded view model over an empty in-memory store, for SwiftUI
    /// previews: a fresh phone store answers "nothing yet," so previews show
    /// the real empty states. Kept out of `#Preview` closures because a
    /// `try!` inside a result builder trips a compiler diagnostic bug.
    static var previewLoaded: PhoneHomeViewModel {
        let viewModel = PhoneHomeViewModel(store: try! SwiftDataStore.phone(at: .inMemory))
        viewModel.load()
        return viewModel
    }
}
#endif
