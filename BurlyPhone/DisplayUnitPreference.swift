// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's display-unit choice (spec §9 Settings: "display unit
// (kg/lb)"). Stored in the phone's own UserDefaults and read with
// `@AppStorage(DisplayUnitPreference.storageKey)` by every view that renders
// a weight. Only the presentation changes: every stored weight stays
// canonical kg (BurlyCore/Weight.swift), and WeightUnit converts on the way
// out and on the way back in.
//
// Apple Watch follows it: the unit rides every sync snapshot (schema 2), and
// the watch renders its weights through the same `WeightUnit`.

import Foundation
import BurlyCore

enum DisplayUnitPreference {
    /// Namespaced like `WelcomeState.persistedKey`.
    static let storageKey = "com.burly.lifting.displayUnit"

    /// What a fresh install shows. Burly has always rendered kilograms, and
    /// the stored values are kilograms.
    static let defaultUnit: WeightUnit = .kilograms

    /// The stored unit, as `@AppStorage` writes it (the raw value).
    static func current(defaults: UserDefaults = .standard) -> WeightUnit {
        defaults.string(forKey: storageKey).flatMap(WeightUnit.init(rawValue:)) ?? defaultUnit
    }

    #if DEBUG
    /// Keeps the persisted unit across a UI-test launch (the relaunch
    /// persistence test). Without it, every scenario launch starts in kg.
    static let keepUnitArgument = "-burly-keep-display-unit"
    #endif

    /// DEBUG-only test seam, the same shape as
    /// `WelcomeState.resetIfRequested`. The simulator keeps UserDefaults
    /// across launches, so a test that switches to lb would otherwise leak
    /// pounds into every later launch — including BurlyPhoneUITests, which
    /// asserts kg strings like "82.5 kg × 12" and passes no unit argument.
    /// So the reset is on by default for any launch that carries the
    /// UI-test scenario key, and a test opts out with `keepUnitArgument`.
    /// Real launches never set the scenario key, and release builds compile
    /// this to nothing (commit 305af63 kept test hooks out of release).
    ///
    /// Called once from `BurlyPhoneApp.init`, which — unlike a view
    /// initializer — SwiftUI does not re-run, so a unit chosen during a
    /// test is never reset underneath it.
    @MainActor
    static func resetForUITestsIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        #if DEBUG
        guard environment[PhoneDemoSeed.environmentKey] != nil,
              !arguments.contains(keepUnitArgument) else { return }
        defaults.removeObject(forKey: storageKey)
        #endif
    }
}
