// SPDX-License-Identifier: GPL-3.0-or-later
// Maps BurlyCore's framework-free `HapticEvent` abstraction (see that
// type's doc: "every engine operation ... returns the haptics it would
// fire ... the watch layer (m2-03+) maps each case onto a
// `WKInterfaceDevice.play(_:)` type") onto the real device.
//
// A protocol, not a bare function, so `SessionViewModel` can be previewed
// and reasoned about without pulling `WatchKit` into every call site --
// the mapping itself has no branching worth a dedicated unit test (it is a
// literal table), so it is exercised by BurlyCore's own `HapticEvent`
// tests plus manual on-device verification, not a new test target.
import Foundation
import BurlyCore
import WatchKit

@MainActor
protocol HapticPlaying: Sendable {
    func play(_ events: [HapticEvent])
}

/// Real device haptics. Distinct waveforms for arm vs. lock (§2: "every
/// lock/unlock transition is a distinct haptic") and for the rest timer's
/// three marks (§3).
struct HapticPlayer: HapticPlaying {
    func play(_ events: [HapticEvent]) {
        for event in events {
            WKInterfaceDevice.current().play(waveform(for: event))
        }
    }

    private func waveform(for event: HapticEvent) -> WKHapticType {
        switch event {
        case .weightEditArmed: .start
        case .weightEditLocked: .stop
        case .setLogged: .success
        case .restTimerWarning: .directionUp
        case .restTimerFinished: .notification
        case .restTimerFinishedRepeat: .notification
        }
    }
}

/// No-op sink for previews and any future headless testing.
struct SilentHapticPlayer: HapticPlaying {
    func play(_ events: [HapticEvent]) {}
}
