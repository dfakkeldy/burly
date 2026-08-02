// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the iPhone shell's shared state from the phone store (spec m5-01):
// the History, Routines, and Stats tabs all render from this one load.
//
// The shell's appearance load is deliberately bounded (m5-01 review
// finding 3): it asks existence/count questions — `hasRoutines()` and
// `loggedSessionCount()` — never full graphs. A decade-old phone store
// holds ~40-50k rows; hydrating every routine's items and every session's
// items→sets just to draw empty states and a workout count was the review's
// exact complaint. The tabs that render rows load them from the store's
// existing surfaces only when that tab is shown (`loadRoutinesForDisplay`
// / `loadSessionsForDisplay`).
//
// The two domains carry independent `LoadState`s (m5-01 review finding 4):
// a failed routine query must not disable History or Stats, and a failed
// session query must not disable Routines — each tab renders only its own
// domain's state, so one failure never replaces valid content in an
// unrelated tab.

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

    // Routines domain (Routines tab).
    private(set) var routinesState: LoadState = .loading
    private(set) var hasRoutines = false
    private(set) var routineRows: [RoutineData] = []

    // Logged-session domain (History and Stats tabs).
    private(set) var sessionsState: LoadState = .loading
    private(set) var loggedSessionCount = 0
    private(set) var sessionRows: [SessionData] = []

    private let store: BurlyStore

    init(store: BurlyStore) {
        self.store = store
    }

    // MARK: - Bounded shell snapshot (finding 3)

    /// The shell's appearance/foreground snapshot: existence and count
    /// only, from the bounded queries — never full graphs. Each domain
    /// loads independently (finding 4), so one failing query does not
    /// disable the other domain's tabs.
    func load() {
        loadRoutines()
        loadSessions()
    }

    /// Routines existence, at routine-table cost.
    func loadRoutines() {
        routinesState = .loading
        do {
            hasRoutines = try store.hasRoutines()
            routinesState = .loaded
        } catch {
            routinesState = .failed(String(describing: error))
        }
    }

    /// Logged-session count, at flat-session-row cost (the Stats scalar).
    func loadSessions() {
        sessionsState = .loading
        do {
            loggedSessionCount = try store.loggedSessionCount()
            sessionsState = .loaded
        } catch {
            sessionsState = .failed(String(describing: error))
        }
    }

    // MARK: - Per-tab display loads (rows only when the tab is shown)

    /// Routines rows — the store's own §9 surface. Called only when the
    /// Routines tab is shown (its `.task`) or its Retry is tapped, never
    /// from the shell's appearance load (finding 3).
    func loadRoutinesForDisplay() {
        routinesState = .loading
        do {
            hasRoutines = try store.hasRoutines()
            routineRows = try store.routines(includingArchived: false)
            routinesState = .loaded
        } catch {
            routinesState = .failed(String(describing: error))
        }
    }

    /// History rows — the store's own §6 history surface. Called only when
    /// the History tab is shown (its `.task`) or its Retry is tapped, never
    /// from the shell's appearance load (finding 3).
    func loadSessionsForDisplay() {
        sessionsState = .loading
        do {
            loggedSessionCount = try store.loggedSessionCount()
            sessionRows = try store.sessions(state: .logged)
            sessionsState = .loaded
        } catch {
            sessionsState = .failed(String(describing: error))
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
