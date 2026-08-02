// SPDX-License-Identifier: GPL-3.0-or-later
// Resolves a `HomeRoute` into a real `SessionEngine` and hands off to
// `LoggingScreenView` -- this is what replaces SessionStartStubView as the
// routine list's navigation destination (spec §2 Start).
//
// §2 Start: "Start creates the Session as a mutable copy of the routine
// (architecture: routine = template, session = mutable copy)." The routine
// list only carries `routineID`/`routineName` (HomeRoute.swift); the full
// `RoutineData` -- items, set counts, rest overrides -- has to be fetched
// here rather than threaded through the route, so a routine that was
// archived or removed between the list rendering and the tap resolving
// surfaces as a clear failure instead of a crash on a stale id.
import SwiftUI
import BurlyCore
import BurlyPersistence

struct SessionEntryView: View {
    let route: HomeRoute
    let store: BurlyStore

    var body: some View {
        let outcome = buildEngine()
        if let engine = outcome.engine {
            LoggingScreenView(engine: engine, store: store)
        } else {
            StoreUnavailableView(message: outcome.errorMessage ?? "Unable to start this workout.")
        }
    }

    private func buildEngine() -> (engine: SessionEngine?, errorMessage: String?) {
        switch route {
        case .emptySession:
            return (SessionEngine(session: SessionBuilder.emptySession(clock: SystemWallClock())), nil)
        case .start(let routineID, _):
            do {
                guard let routine = try store.routine(id: routineID) else {
                    return (nil, "This routine is no longer available.")
                }
                let session = SessionBuilder.session(from: routine, clock: SystemWallClock())
                return (SessionEngine(session: session), nil)
            } catch {
                return (nil, String(describing: error))
            }
        }
    }
}
