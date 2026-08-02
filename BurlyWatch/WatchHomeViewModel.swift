// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the watch home's state from the store (spec §2 Start, §5 fresh
// install). BurlySync's snapshot/digest transport is a later milestone --
// routines can only reach the watch store through it (routine authoring is
// phone-only, §9), so an empty routine list today always means "nothing has
// arrived from the iPhone yet," exactly the §5 "waiting for iPhone" case.
//
// ## Resume (m2-06)
//
// §2 "Always-On & recovery": "Relaunch with an `.active` session in store
// → Resume screen ... Declining resume = normal end-workout summary path."
// That is a home-shell-level gate, not something reachable only after the
// lifter picks a routine -- so `load()` checks `resumableActiveSession()`
// *first*, before ever computing the routine list, exactly like it already
// treats an empty routine list as "waiting for iPhone" rather than showing
// an empty list. One consequence worth being explicit about: with this
// gate in place, the routine list is never shown while a session is
// active, so `RoutineListView` -> `SessionEntryView`'s own defensive
// `resumableActiveSession()` pre-check (`SessionConflictView`'s doc) should
// no longer be reachable in ordinary use -- it stays as a second layer
// rather than being removed, since this file is the only thing that would
// have to keep proving that claim if it were the sole guard.
//
// ## An unreadable journal must never wedge the gate (m2-06 review finding
// 2.1)
//
// `resumableActiveSession()` throws `.unreadableActiveSessionJournal
// (sessionID:)` -- never returns a partial/invented `ActiveSession` --
// when the journal it settles on is present but its payload will not
// decode (`SwiftDataStore.makeActiveSession`'s doc: "fails closed rather
// than resuming a session with invented scaffolding"). That is exactly
// right for the store to refuse, but the pre-fix `load()` folded it into
// the same generic `.failed` bucket as any other store error, and
// `StoreUnavailableView`'s only affordance is Retry -- which just calls
// `load()` again, hits the identical undecodable journal, and fails
// identically forever. Resume, Finish, Discard, the routine list, and
// Start all become unreachable: the corrupt row can never repair itself,
// and nothing else in this state can remove it.
//
// So this error gets its own `LoadState` case (`.unreadableSession`)
// instead, with a named recovery: `discardUnreadableSession(_:)` calls
// `store.deleteSession(id:)` directly on the *named* session id the error
// itself carries. That call is safe against an undecodable journal on
// purpose -- `deleteSession` never reads `ActiveSessionJournal.payload`,
// only deletes the row by id (`SwiftDataStore.deleteSession`'s doc) -- so
// it cleanly removes both the corrupt journal and its session without
// ever needing to decode the very thing that's broken.
//
// This is deliberately a single, clearly-destructive tap rather than §2's
// normal double-confirm Discard: an ordinary Discard gives up a workout
// the lifter can see and might reconsider, but there is nothing to show
// here -- the data is provably unreadable, so a second confirmation step
// would only be asking the lifter to reconfirm blind. The alternative is
// staying permanently wedged, which costs far more than one plain button.
import Foundation
import BurlyCore
import BurlyPersistence
import Observation

/// Confines the store read and the observed `state` to the main actor
/// (m2-01 review finding 3.2) -- today's only caller is SwiftUI-bound
/// anyway, but encoding that as a compiler-checked fact means a later
/// sync/background callback (M4's transport) cannot call `load()` from
/// off-main without an explicit, visible hop.
@MainActor
@Observable
final class WatchHomeViewModel {
    enum LoadState: Equatable {
        case loading
        case waitingForPhone
        /// §2 Resume gate (m2-06): an `.active` session was found. Takes
        /// priority over every other state -- see `load()`.
        case resumable(ResumablePreview)
        /// m2-06 review finding 2.1: the one session in flight exists but
        /// its journal is undecodable. Distinct from `.failed` on purpose
        /// -- see the file doc -- so the shell can offer a targeted
        /// recovery (`discardUnreadableSession(_:)`) instead of a Retry
        /// that can never succeed.
        case unreadableSession(sessionID: UUID)
        case loaded([RoutineRow])
        case failed(String)
    }

    /// What `ResumeSessionView` needs to render its prompt, without
    /// carrying the full `ActiveSession` graph into view-layer state (the
    /// session itself is re-fetched at `SessionEntryView` once the lifter
    /// actually picks an action -- see `HomeRoute.resume`'s doc).
    struct ResumablePreview: Equatable {
        let sessionID: UUID
        /// §1: denormalized onto the session itself, so this reads even
        /// after the routine that started it was archived or deleted.
        /// `nil` for §2's "Empty session" start, which never names a
        /// routine at all -- not an error case, so `ResumeSessionView`
        /// renders a plain fallback rather than treating it as one.
        let routineName: String?
        let startedAt: Date
        let loggedSetCount: Int
    }

    struct RoutineRow: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// Spec §2: "each row shows name + 'last done N days ago'."
        let lastDoneText: String
    }

    private(set) var state: LoadState = .loading

    private let store: BurlyStore
    private let now: () -> Date

    init(store: BurlyStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func load() {
        do {
            if let resumable = try store.resumableActiveSession() {
                state = .resumable(
                    ResumablePreview(
                        sessionID: resumable.id,
                        routineName: resumable.session.routineName,
                        startedAt: resumable.session.startedAt,
                        loggedSetCount: resumable.allSets.count
                    )
                )
                return
            }

            let routines = try store.routines(includingArchived: false)
            guard !routines.isEmpty else {
                state = .waitingForPhone
                return
            }

            let loggedSessions = try store.sessions(state: .logged)
            let reference = now()
            state = .loaded(routines.map { routine in
                RoutineRow(
                    id: routine.id,
                    name: routine.name,
                    lastDoneText: Self.lastDoneText(
                        for: routine.id,
                        loggedSessions: loggedSessions,
                        reference: reference
                    )
                )
            })
        } catch BurlyStoreError.unreadableActiveSessionJournal(let sessionID) {
            // m2-06 review finding 2.1: named recovery, never the generic
            // Retry-only `.failed` -- see the file doc.
            state = .unreadableSession(sessionID: sessionID)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// m2-06 review finding 2.1: the only way out of `.unreadableSession`.
    /// `deleteSession` never touches the corrupt journal payload -- see the
    /// file doc -- so this is safe to call on exactly the session named by
    /// the error that produced this state. Reloads afterward so the shell
    /// lands on whatever is genuinely true next (the routine list, or
    /// "waiting for iPhone" if that was the only thing ever seeded).
    ///
    /// A failure here falls through to the ordinary `.failed` state rather
    /// than a bespoke one: `load()` will re-diagnose fresh on Retry, and
    /// because it re-throws the same `.unreadableActiveSessionJournal` for
    /// as long as the row is still corrupt, Retry lands back on this exact
    /// recovery screen rather than a dead end -- a failed delete here is a
    /// transient store problem, not a second wedge.
    func discardUnreadableSession(_ sessionID: UUID) {
        do {
            _ = try store.deleteSession(id: sessionID)
            load()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// `sessions(state:)` is already reverse-chronological (BurlyStore.swift
    /// doc), so the first match for a routine is its most recent session.
    private static func lastDoneText(
        for routineID: UUID,
        loggedSessions: [SessionData],
        reference: Date
    ) -> String {
        guard let last = loggedSessions.first(where: { $0.routineID == routineID }) else {
            return "Never done"
        }

        let days = Calendar.current.dateComponents([.day], from: last.startedAt, to: reference).day ?? 0
        switch days {
        case ..<1: return "Last done today"
        case 1: return "Last done 1 day ago"
        default: return "Last done \(days) days ago"
        }
    }
}
