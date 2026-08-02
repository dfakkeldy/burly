// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Guarded weight edit (the deliberate-gesture arm)". The UI layer
// over `GuardedWeightEditMachine` (BurlyCore) -- this view holds no lock
// logic of its own; every state transition is asked of `SessionViewModel`,
// which asks the engine. What lives here is purely: how locked/armed
// *looks*, the long-press gesture that arms it, and the crown/micro-button
// wiring that only does anything while armed (the machine also refuses an
// `.adjust` while locked, so this is belt-and-suspenders, not the only
// guard).
//
// Weight is displayed in pounds (Dan's imperial/US context; no unit
// setting exists yet -- that is phone-side, later work) via `Weight
// .pounds`, rounded to the nearest 0.5 lb for display only, exactly as
// that property's doc requires ("never round-trip back into kg").
import SwiftUI
import BurlyCore

struct GuardedWeightControlView: View {
    let weight: Weight
    let isArmed: Bool
    let onArm: () -> Void
    let onAdjustSteps: (Int) -> Void

    @State private var crownRotation: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isArmed ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(isArmed ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(weightText)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(isArmed ? Color.accentColor : .primary)
                    .contentTransition(.numericText())
            }

            if isArmed {
                HStack(spacing: 20) {
                    Button { onAdjustSteps(-1) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Decrease weight")
                    Button { onAdjustSteps(1) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Increase weight")
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // §2: "Arm: long-press (≈0.5 s) the weight value."
        .onLongPressGesture(minimumDuration: 0.5) {
            onArm()
        }
        // §2: "crown adjusts" only while armed; `.focusable(false)` keeps
        // the crown free for the page/reps control while locked.
        .focusable(isArmed)
        .digitalCrownRotation(
            $crownRotation,
            from: -1_000_000,
            through: 1_000_000,
            by: 1,
            sensitivity: .medium,
            isContinuous: true,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownRotation) { old, new in
            guard isArmed else { return }
            let steps = Int((new - old).rounded())
            if steps != 0 { onAdjustSteps(steps) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("weightControl")
        .accessibilityLabel("Weight")
        // §2 acceptance #3: "the accessibility tree asserts the weight
        // control exposes locked/armed state" -- literally in the value.
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            guard isArmed else { return }
            switch direction {
            case .increment: onAdjustSteps(1)
            case .decrement: onAdjustSteps(-1)
            @unknown default: break
            }
        }
        // A VoiceOver-reachable equivalent to the long press (axiom-
        // accessibility: custom gestures need an accessible alternative).
        .accessibilityAction(named: Text("Arm weight editing")) {
            onArm()
        }
    }

    private var displayPounds: Double {
        (weight.pounds * 2).rounded() / 2
    }

    private var weightText: String {
        String(format: "%.1f lb", displayPounds)
    }

    private var accessibilityValueText: String {
        "\(weightText), \(isArmed ? "armed" : "locked")"
    }
}

#Preview("Locked") {
    GuardedWeightControlView(weight: Weight(kg: 60), isArmed: false, onArm: {}, onAdjustSteps: { _ in })
}

#Preview("Armed") {
    GuardedWeightControlView(weight: Weight(kg: 60), isArmed: true, onArm: {}, onAdjustSteps: { _ in })
}
