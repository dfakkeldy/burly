// SPDX-License-Identifier: MIT
// What the watch takes from the phone's Settings (sync snapshot schema 2):
// the display unit every weight renders in, and the §3 global rest default
// that ends the rest ladder (an exercise's own rest, then the routine's,
// then this). Before the first snapshot arrives these are the phone's own
// defaults, kilograms and 90 s.

import SwiftUI
import BurlyCore

struct WatchSyncedSettings: Equatable {
    var displayUnit: WeightUnit = .kilograms
    var restDefault: TimeInterval = RestDuration.globalDefault
    /// §2's 3 s auto-lock for an armed weight. Not synced: only a DEBUG
    /// UI-test launch key changes it (`WatchDemoSeed`), so tests that
    /// look at an armed weight are not outrun by slow accessibility reads.
    var weightIdleTimeout: TimeInterval = GuardedWeightEditMachine.Configuration().idleTimeout

    /// §2: "crown adjusts in configurable increments (default 2.5 lb /
    /// 1.25 kg equivalent)". The step follows the unit so the numbers a
    /// lifter scrolls through are plate numbers in their own system.
    var weightIncrement: Weight {
        switch displayUnit {
        case .kilograms: Weight(kg: 1.25)
        case .pounds: Weight(pounds: 2.5)
        }
    }

    /// The one way the watch builds a `SessionEngine`, so every Start,
    /// Resume and conflict-Finish path uses the synced rest default and
    /// weight step.
    func engine(for session: ActiveSession) -> SessionEngine {
        SessionEngine(
            session: session,
            restConfiguration: RestTimerConfiguration(globalDefault: restDefault),
            weightEditConfiguration: GuardedWeightEditMachine.Configuration(
                idleTimeout: weightIdleTimeout,
                increment: weightIncrement
            )
        )
    }
}

extension EnvironmentValues {
    @Entry var watchSettings = WatchSyncedSettings()
    /// Finish durably stored this session as logged: queue it for the phone
    /// (§5 outbox, immediate attempt). A no-op without sync (UI tests).
    @Entry var sessionLogged: @MainActor @Sendable (UUID) -> Void = { _ in }
}
