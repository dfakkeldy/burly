// SPDX-License-Identifier: GPL-3.0-or-later
// The one-time first-launch welcome decision (spec m5-01): "the choice
// persists (relaunches skip welcome)."
//
// Real launches decide from the persisted flag in UserDefaults. Debug
// launches (UI tests) can override it with launch arguments instead, so
// BurlyPhoneUITests can force either side deterministically no matter what a
// previous run persisted -- the same DEBUG-only, out-of-process seam pattern
// BurlyWatch's WatchDemoSeed provides for store scenarios. The argument
// names are matched literally by BurlyPhoneUITests.swift (the UI test target
// runs out-of-process and cannot share code with the app).

import Foundation

enum WelcomeState {

    /// Persisted once the user makes either first-launch choice.
    static let persistedKey = "com.burly.lifting.welcomeCompleted"

    #if DEBUG
    /// Force the welcome to show, even if `persistedKey` is already set.
    static let forceWelcomeArgument = "-burly-force-welcome"
    /// Force the welcome to be skipped, even on a genuine fresh install.
    static let skipWelcomeArgument = "-burly-skip-welcome"
    /// Remove the persisted welcome flag before the test's first launch
    /// (m5-01 review finding 5): a persistence test must prove the genuine
    /// uncompleted state — a stale `true` left by an earlier test in the
    /// same suite run would otherwise let the relaunch assertion pass even
    /// when `markCompleted()` is broken. This removes **only** the
    /// namespaced welcome key; nothing else in UserDefaults is touched.
    static let resetWelcomeArgument = "-burly-reset-welcome"
    #endif

    /// Compile-time-gated reset seam (m5-01 review finding 5): when
    /// `resetWelcomeArgument` is present, removes `persistedKey` so the
    /// next `isCompleted()` read sees the genuine uncompleted state. Called
    /// from `ContentView.init` before the first read; real launches never
    /// pass the argument, so this is a no-op for them.
    static func resetIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        #if DEBUG
        guard arguments.contains(resetWelcomeArgument) else { return }
        defaults.removeObject(forKey: persistedKey)
        #endif
    }

    /// `true` once the user has made the first-launch choice.
    ///
    /// - Parameters:
    ///   - defaults: injectable for tests; real launches pass `.standard`.
    ///   - arguments: injectable for tests; real launches pass
    ///     `ProcessInfo.processInfo.arguments`.
    static func isCompleted(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG
        if arguments.contains(forceWelcomeArgument) { return false }
        if arguments.contains(skipWelcomeArgument) { return true }
        #endif
        return defaults.bool(forKey: persistedKey)
    }

    /// Records the first-launch choice. Idempotent: either button may call
    /// it, and calling it again is harmless.
    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: persistedKey)
    }
}
