// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WatchKit
import os
import BurlyCore
import BurlyHealth
import BurlyPersistence
import BurlySyncAdapters
import BurlyWatchSyncRuntime

extension EnvironmentValues {
    /// Spec §4's session-level HealthKit recorder, shared by every session
    /// the app runs so a resumed session finds the workout HealthKit kept
    /// alive. `nil` when Health is switched off for a UI-test scenario.
    @Entry var workoutRecorder: SessionWorkoutRecorder? = nil
}

@main
struct BurlyWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
        }
    }
}

/// Owns `WatchAppModel` and is Watch Connectivity's way in. §5's background
/// budget: every `WKWatchConnectivityRefreshBackgroundTask` is retained by
/// the sync host and completed only once WCSession is activated with no
/// content pending; any other task, or any task without sync, completes at
/// once.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let model = WatchAppModel()

    func applicationDidFinishLaunching() {
        model.sync?.activate()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask, let sync = model.sync {
                sync.retainBackgroundTask(SystemWCRefreshBackgroundTask(connectivityTask))
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

/// The watch's one store, its sync host, and the session-level HealthKit
/// recorder, resolved exactly once for this launch (m2-01 review finding
/// 3.1: never from a view `body`, which SwiftUI re-evaluates freely). It
/// lives on the app delegate because Watch Connectivity can wake the app
/// with no view on screen, and the sync coordinator must apply into the
/// same store the UI reads.
///
/// A real launch uses the on-device store, which starts empty until the
/// phone's first snapshot arrives -- the §5 "waiting for iPhone" case.
/// BurlyWatchUITests requests an isolated in-memory scenario instead (see
/// WatchDemoSeed.swift), and those launches get no sync: the standalone UI
/// tests must not touch WCSession, and a seeded or fault-wrapped store is
/// not the on-device working set. They also get no Health unless the test
/// opts in, so the authorization sheet does not cover the screens those
/// suites drive.
@MainActor
final class WatchAppModel {
    let storeResult: Result<BurlyStore, Error>
    let sync: WatchSyncHost?
    let workoutRecorder: SessionWorkoutRecorder?

    init() {
        workoutRecorder = Self.makeWorkoutRecorder()
        #if DEBUG
        // Once a scenario is recognized, WatchDemoSeed fails closed: its
        // Result is used as-is, success or failure, and never falls through
        // to the on-device store below (m2-01 review finding 2.1).
        if let requested = WatchDemoSeed.requestedStore() {
            storeResult = requested
            sync = nil
            return
        }
        #endif
        do {
            let store = try SwiftDataStore.watch()
            storeResult = .success(store)
            sync = Self.makeSync(store: store)
        } catch {
            storeResult = .failure(error)
            sync = nil
        }
    }

    /// A store that opened but whose sync state could not be read still
    /// runs the app: workouts log locally and stay in the outbox until a
    /// later launch can send them. WCSession is then never activated, so the
    /// phone's transfers wait in Watch Connectivity rather than arriving
    /// into nothing.
    private static func makeSync(store: SwiftDataStore) -> WatchSyncHost? {
        do {
            return try WatchSyncHost(store: store, session: SystemWCSessionTransport())
        } catch {
            Logger(subsystem: "com.burly.lifting", category: "sync.watch")
                .error("sync not started: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// No Health at all in a seeded UI-test scenario unless the test opts
    /// in: the authorization sheet would otherwise cover the screens the
    /// existing suites drive.
    private static func makeWorkoutRecorder() -> SessionWorkoutRecorder? {
        #if DEBUG
        if WatchDemoSeed.isScenarioRequested, !WatchDemoSeed.wantsLiveHealth {
            return nil
        }
        #endif
        let health = HealthKitWorkoutStore()
        var factory: any WorkoutSessionCreating = health.makeSessionFactory()
        #if DEBUG
        if WatchDemoSeed.wantsNoLiveSensors {
            factory = NoLiveWorkoutFactory()
        }
        #endif
        return SessionWorkoutRecorder(
            store: health,
            controller: WorkoutController(factory: factory)
        )
    }
}

@MainActor
private struct RootView: View {
    let model: WatchAppModel

    var body: some View {
        switch model.storeResult {
        case .success(let store):
            ContentView(store: store, sync: model.sync)
                .environment(\.watchSettings, settings)
                .environment(\.sessionLogged, { [sync = model.sync] id in sync?.sessionLogged(id: id) })
                .environment(\.workoutRecorder, model.workoutRecorder)
                .task { reconcileWorkout(with: store) }
        case .failure(let error):
            StoreUnavailableView(message: String(describing: error))
        }
    }

    /// Read in `body`, so a newly applied snapshot re-renders with the
    /// phone's new unit and rest default.
    private var settings: WatchSyncedSettings {
        guard let sync = model.sync else { return WatchSyncedSettings() }
        return WatchSyncedSettings(displayUnit: sync.displayUnit, restDefault: sync.restDefault)
    }

    /// Spec §4 recovery matrix at launch: a workout HealthKit kept running
    /// is reattached to the store's active session, or discarded when the
    /// store has none. An unreadable store leaves HealthKit alone; the
    /// orphan, if any, is discarded when the next session starts.
    private func reconcileWorkout(with store: BurlyStore) {
        guard let workoutRecorder = model.workoutRecorder else { return }
        let active: ActiveSession?
        do {
            active = try store.resumableActiveSession()
        } catch {
            return
        }
        workoutRecorder.reconcile(activeSessionID: active?.id)
    }
}

#if DEBUG
/// `BURLY_WATCH_UI_TEST_HEALTH=noLiveSensors`: every live workout fails to
/// start, so a finished session takes the duration-only path against real
/// HealthKit.
private final class NoLiveWorkoutFactory: WorkoutSessionCreating {
    func makeLiveWorkout(configuration _: WorkoutConfiguration) throws -> LiveWorkoutResources {
        throw WorkoutHealthError.operationFailed("UI test: no live sensors")
    }
}
#endif
