// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's global rest default (spec §9 Settings: "global rest default";
// §3: 15 s–5 min in 15 s steps, 90 s by default). Stored in the phone's own
// UserDefaults like `DisplayUnitPreference`, edited in Settings, and carried
// to Apple Watch in every sync snapshot, where it ends §3's rest ladder:
// an exercise's own rest, then the routine's, then this.

import Foundation
import BurlyCore

enum RestDefaultPreference {
    /// Namespaced like `DisplayUnitPreference.storageKey`.
    static let storageKey = "com.burly.lifting.restDefault"

    /// The §3 global default, until the lifter changes it.
    static let defaultSeconds: TimeInterval = RestDuration.globalDefault

    static var range: ClosedRange<TimeInterval> { RestDuration.minimum...RestDuration.maximum }
    static var step: TimeInterval { RestDuration.step }

    #if DEBUG
    /// Keeps the persisted rest default across a UI-test launch.
    static let keepRestArgument = "-burly-keep-rest-default"
    #endif

    /// The stored default, on the §3 grid whatever was written.
    static func current(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: storageKey) != nil else { return defaultSeconds }
        return RestDuration.clamped(defaults.double(forKey: storageKey))
    }

    /// The same DEBUG-only reset seam as
    /// `DisplayUnitPreference.resetForUITestsIfRequested`, for the same
    /// reason: the simulator keeps UserDefaults across launches, and the
    /// Settings test reads "1:30" on a reset launch.
    @MainActor
    static func resetForUITestsIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        #if DEBUG
        guard environment[PhoneDemoSeed.environmentKey] != nil,
              !arguments.contains(keepRestArgument) else { return }
        defaults.removeObject(forKey: storageKey)
        #endif
    }
}
