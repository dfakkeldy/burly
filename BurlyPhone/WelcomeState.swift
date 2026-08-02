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
    #endif

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
