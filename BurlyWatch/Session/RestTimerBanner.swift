// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §3 rest-timer presentation for the logging screen. `RestTimerState`
// is deliberately the input: this view renders its stored wall-clock dates
// through `TimelineView`, but delegates every mutation and every haptic
// decision to SessionViewModel -> SessionEngine -> RestTimerEngine.
import SwiftUI
import BurlyCore

struct RestTimerBanner: View {
    let timer: RestTimerState
    let onAdjust: (TimeInterval) -> Void
    let onSkip: () -> Void

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        // `PeriodicTimelineSchedule` is evaluated by SwiftUI in its
        // `.lowFrequency` mode while Always-On is dimmed. A second is both
        // the required Always-On resolution and all a wall-clock countdown
        // needs; there is no accumulating Timer anywhere in this view.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, timer.endDate.timeIntervalSince(context.date))

            if isLuminanceReduced {
                lowFrequencyCountdown(remaining: remaining)
            } else {
                activeCountdown(remaining: remaining)
            }
        }
    }

    /// The full, active rendering: a progress ring around the remaining
    /// time, flanked by explicit 44 pt adjustment targets.
    private func activeCountdown(remaining: TimeInterval) -> some View {
        HStack(spacing: 8) {
            adjustmentButton(delta: -15, title: "-15", identifier: "restTimer.decreaseButton")

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.25), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: progress(for: remaining))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                remainingLabel(remaining: remaining)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .onTapGesture(perform: onSkip)

            adjustmentButton(delta: 15, title: "+15", identifier: "restTimer.increaseButton")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    /// In the luminance-reduced branch, retain the useful information at the
    /// supported 1 Hz cadence without keeping the decorative ring bright.
    /// The countdown remains the same 44 pt confirm-free skip target.
    private func lowFrequencyCountdown(remaining: TimeInterval) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .accessibilityHidden(true)
            remainingLabel(remaining: remaining)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSkip)
    }

    private func adjustmentButton(delta: TimeInterval, title: String, identifier: String) -> some View {
        Button {
            onAdjust(delta)
        } label: {
            Text(title)
                .font(.caption.bold())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        // Leaf identifiers only: a parent identifier replaces descendants
        // in the watch accessibility tree.
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(delta < 0 ? "Subtract 15 seconds from rest" : "Add 15 seconds to rest")
    }

    private func remainingLabel(remaining: TimeInterval) -> some View {
        Text(formatted(remaining))
            .font(.system(.body, design: .rounded, weight: .medium))
            .monospacedDigit()
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("restTimer.remaining")
            .accessibilityLabel("Rest remaining")
            .accessibilityValue("\(Int(remaining.rounded(.up))) seconds")
            .accessibilityAction(named: Text("Skip rest")) { onSkip() }
    }

    private func progress(for remaining: TimeInterval) -> CGFloat {
        guard timer.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, remaining / timer.duration)))
    }

    private func formatted(_ remaining: TimeInterval) -> String {
        let whole = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

#Preview("Active") {
    RestTimerBanner(
        timer: RestTimerState(startedAt: .now, duration: 90),
        onAdjust: { _ in },
        onSkip: {}
    )
}

#Preview("Always On") {
    RestTimerBanner(
        timer: RestTimerState(startedAt: .now, duration: 90),
        onAdjust: { _ in },
        onSkip: {}
    )
    .environment(\.isLuminanceReduced, true)
}
