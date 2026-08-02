// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the watch home's state from the store (spec §2 Start, §5 fresh
// install). BurlySync's snapshot/digest transport is a later milestone --
// routines can only reach the watch store through it (routine authoring is
// phone-only, §9), so an empty routine list today always means "nothing has
// arrived from the iPhone yet," exactly the §5 "waiting for iPhone" case.

import Foundation
import BurlyCore
import BurlyPersistence
import Observation

@Observable
final class WatchHomeViewModel {
    enum LoadState: Equatable {
        case loading
        case waitingForPhone
        case loaded([RoutineRow])
        case failed(String)
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
