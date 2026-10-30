// SPDX-License-Identifier: GPL-3.0-or-later
// The phone app's one store and its sync host (m4-06).
//
// One store per process: the sync coordinator ingests watch sessions into
// the same `SwiftDataStore` the tabs read and edit (the binding contract's
// single executor), so the store moved here from `ContentView`'s `@State`
// and the shell reads it from this model.
//
// Sync starts at launch, from the app delegate, not from a view: Watch
// Connectivity can launch the app in the background to deliver a session,
// and no view is built then. A returning user (welcome already completed)
// gets the store and WCSession at launch. On a first launch the welcome is
// still decided from its flag alone (m5-01 finding 1), and the store and
// sync start when the tab shell is entered, exactly as the store did before.
//
// UI-test scenarios get their seeded in-memory store and no sync: the
// standalone UI tests must not touch WCSession, and an in-memory store has
// no business owning an on-disk sync journal.

import Foundation
import Observation
import os
import BurlyPersistence
import BurlyPhoneSync
import BurlySyncAdapters
import WatchConnectivity

@MainActor
@Observable
final class PhoneAppModel {
    private(set) var storeResult: Result<BurlyStore, Error>?
    private(set) var sync: PhoneSyncHost?

    /// The app delegate's launch hook: a returning user's store and sync.
    func launch() {
        #if DEBUG
        if ProcessInfo.processInfo.environment[PhoneDemoSeed.environmentKey] != nil { return }
        #endif
        guard WelcomeState.isCompleted() else { return }
        resolveStore()
    }

    /// Builds the store once. Retry reaches this only after a failure, so an
    /// existing working store is never discarded and rebuilt. The DEBUG
    /// branch consults `PhoneDemoSeed` first so UI tests get deterministic
    /// in-memory scenarios; a recognized scenario that fails to seed comes
    /// back as a `.failure`, never the on-device store (m5-01 finding 6).
    func resolveStore() {
        if case .success = storeResult { return }
        #if DEBUG
        if let seeded = PhoneDemoSeed.requestedStore() {
            storeResult = seeded
            return
        }
        #endif
        do {
            let store = try SwiftDataStore.phone()
            storeResult = .success(store)
            startSync(store)
        } catch {
            storeResult = .failure(error)
        }
    }

    private func startSync(_ store: BurlyStore) {
        guard sync == nil, WCSession.isSupported() else { return }
        do {
            let host = PhoneSyncHost(
                store: store,
                session: SystemWCSessionTransport(),
                // No legacy two-file paths: no shipped build ever constructed
                // the file-backed state, so no device holds the old files.
                statePersisting: FileBackedPhoneSyncStatePersisting(url: try Self.journalURL()),
                watchSettings: {
                    PhoneWatchSettings(
                        displayUnit: DisplayUnitPreference.current(),
                        restDefault: RestDefaultPreference.current()
                    )
                },
                isWatchAppInstalled: { WCSession.default.isWatchAppInstalled }
            )
            sync = host
            host.activate()
        } catch {
            Logger(subsystem: "com.burly.lifting", category: "sync.phone")
                .error("sync not started: \(String(describing: error), privacy: .public)")
        }
    }

    /// Beside the store, in Application Support/Burly, which the store has
    /// already created by the time this runs.
    private static func journalURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "Burly", directoryHint: .isDirectory)
            .appending(path: "phone-sync.journal", directoryHint: .notDirectory)
    }
}
