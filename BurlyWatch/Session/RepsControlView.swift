// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 input model: "Reps: +/- buttons (large tap targets), crown
// adjusts when focused." Reps have no lock -- only weight does -- so this
// is a plain adjustable control, collapsed into one accessibility element
// per axiom-accessibility's custom-adjustable-control pattern (a stepper
// built from raw buttons reads terribly to VoiceOver otherwise).
import SwiftUI

struct RepsControlView: View {
    let reps: Int
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onAdjustSteps: (Int) -> Void

    @State private var crownRotation: Double = 0

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onDecrement) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            Text("\(reps)")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
                .frame(minWidth: 32)
            Button(action: onIncrement) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
        .focusable(true)
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
            let steps = Int((new - old).rounded())
            if steps != 0 { onAdjustSteps(steps) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("repsControl")
        .accessibilityLabel("Reps")
        .accessibilityValue("\(reps)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIncrement()
            case .decrement: onDecrement()
            @unknown default: break
            }
        }
    }
}

#Preview {
    RepsControlView(reps: 8, onIncrement: {}, onDecrement: {}, onAdjustSteps: { _ in })
}
