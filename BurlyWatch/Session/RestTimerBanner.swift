// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §3 hosting seam: "Runs on the logging screen: countdown ring
// around/near the Log button area + remaining time ... Adjust in flight:
// +15 s / -15 s buttons; tap countdown -> skip." The polished ring/
// animation treatment is m2-05's job (per this task's brief); what lives
// here is the real, wall-clock-driven entry point m2-05 replaces in place
// -- remaining time, +15/-15, and tap-to-skip, all wired straight to
// `SessionEngine`'s already-tested rest-timer methods.
//
// Deliberately not itself a `TimelineView` -- the caller (`ExercisePageView`,
// inside `LoggingScreenView`'s screen-wide 1 Hz `TimelineView`, §2 Always-
// On) supplies `remaining` freshly every tick, so this view stays a plain,
// static render of whatever it's handed and never starts a second clock.
import SwiftUI

struct RestTimerBanner: View {
    let remaining: TimeInterval
    let onAdjust: (TimeInterval) -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onAdjust(-15)
            } label: {
                Text("-15")
                    // m2-03 review finding 11: rest-adjust buttons were
                    // caption-sized text with no minimum hit region --
                    // explicit frame, visual size unchanged.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("restTimer.decreaseButton")
            .accessibilityLabel("Subtract 15 seconds from rest")

            Text(formatted)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
                // m2-03 review finding 11: the skip target had a 44 pt
                // minimum width but no minimum height.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { onSkip() }
                .accessibilityIdentifier("restTimer.remaining")
                .accessibilityLabel("Rest remaining")
                .accessibilityValue("\(Int(remaining)) seconds")
                .accessibilityAction(named: Text("Skip rest")) { onSkip() }

            Button {
                onAdjust(15)
            } label: {
                Text("+15")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("restTimer.increaseButton")
            .accessibilityLabel("Add 15 seconds to rest")
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .padding(.vertical, 2)
        .accessibilityIdentifier("restTimerBanner")
    }

    private var formatted: String {
        let whole = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

#Preview {
    RestTimerBanner(remaining: 75, onAdjust: { _ in }, onSkip: {})
}
