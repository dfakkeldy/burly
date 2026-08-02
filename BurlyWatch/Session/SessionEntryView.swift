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
//
// ## Engine construction is an explicit event, not a side effect of `body`
// (m2-03 review finding 2)
//
// The previous shape built a fresh `SessionEngine` -- new session/item
// UUIDs every time -- straight from a computed `body`, and `LoggingScreenView
// .init` then constructed a `SessionViewModel` whose initializer wrote it to
// the store immediately. SwiftUI may re-evaluate `body` (and re-run a
// view's `init`) for reasons that have nothing to do with the user asking
// to start a workout -- a parent re-render, a diffing pass it later
// discards -- and by the time it decides to keep or throw away that value,
// the store write already happened. `start()` below is the one place a
// `SessionEngine` is built and durably saved, and it runs from `.task`,
// which SwiftUI guarantees fires once per this view's actual *appearance*
// in the hierarchy, not once per `body`/`init` evaluation.
//
// ## The blocker (m2-03 review finding 1, scoped)
//
// Building the full §2/§4 Resume flow -- reattaching to an existing active
// session's *own* logging screen on relaunch -- is m2-06's task. What this
// view must never do is let a second `Start` reach an unsaved logging
// screen while a session is already in flight: `store
// .saveActiveSession(_:)` refuses a second `.active` session
// (`.activeSessionAlreadyInFlight`), and the old code only wrote that
// refusal into an unused `errorMessage` while the (now-broken) logging
// screen stayed up and running. `start()` checks `resumableActiveSession()`
// *before* ever building a new engine; if one is already in flight, this
// routes to `SessionConflictView`'s finish-or-discard choice against that
// EXISTING session instead.
import SwiftUI
import BurlyCore
import BurlyPersistence

struct SessionEntryView: View {
    let route: HomeRoute
    let store: BurlyStore

    private enum Phase {
        case checking
        case conflict(ActiveSession)
        case ready(SessionEngine)
        case failed(String)
    }

    @State private var phase: Phase = .checking

    var body: some View {
        Group {
            switch phase {
            case .checking:
                ProgressView()
            case .conflict(let existing):
                SessionConflictView(existing: existing, store: store, onResolved: start)
            case .ready(let engine):
                LoggingScreenView(engine: engine, store: store)
            case .failed(let message):
                StoreUnavailableView(message: message)
            }
        }
        .task {
            guard case .checking = phase else { return }
            start()
        }
    }

    /// The one explicit Start/Resume event (see file doc above). Re-entrant
    /// on purpose -- `SessionConflictView`'s `onResolved` calls it again
    /// once the blocking conflict is cleared, so the originally-requested
    /// route proceeds immediately rather than making the lifter tap Start
    /// twice.
    private func start() {
        phase = .checking
        do {
            if let existing = try store.resumableActiveSession() {
                phase = .conflict(existing)
                return
            }
        } catch {
            phase = .failed(String(describing: error))
            return
        }

        switch route {
        case .emptySession:
            let engine = SessionEngine(session: SessionBuilder.emptySession(clock: SystemWallClock()))
            saveAndEnter(engine)
        case .start(let routineID, _):
            do {
                guard let routine = try store.routine(id: routineID) else {
                    phase = .failed("This routine is no longer available.")
                    return
                }
                let session = SessionBuilder.session(from: routine, clock: SystemWallClock())
                saveAndEnter(SessionEngine(session: session))
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    /// The single point that durably saves a freshly-built engine before
    /// ever showing it (§2 Start: "navigates to the logging screen" implies
    /// the session already exists to navigate to). `SessionViewModel` no
    /// longer saves from its own initializer -- see its doc.
    private func saveAndEnter(_ engine: SessionEngine) {
        do {
            try store.saveActiveSession(engine.session)
            phase = .ready(engine)
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
