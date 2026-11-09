// SPDX-License-Identifier: MIT
// Spec §2 input model: "Reps: +/- buttons (large tap targets), crown
// adjusts when focused." Reps have no lock -- only weight does -- so this
// is a plain adjustable control, collapsed into one accessibility element
// per axiom-accessibility's custom-adjustable-control pattern (a stepper
// built from raw buttons reads terribly to VoiceOver otherwise).
//
// `reps` is `Int?` (m2-03 review finding 3): `nil` means the §2 prefill
// ladder came back `.empty` and nothing has been entered yet -- rendered as
// a plain dash, never an invented number like the old hardcoded "8"
// fallback. `SessionViewModel.incrementReps()`/`decrementReps()` already
// treat `nil` correctly; this view only has to display it honestly.
import SwiftUI

struct RepsControlView: View {
    let reps: Int?
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onAdjustSteps: (Int) -> Void

    @State private var crownRotation: Double = 0

    /// Compact enough to sit beside the weight on a 42 mm screen: the two
    /// 44 pt buttons touch the number, and "reps" sits under it the way
    /// the unit sits under the weight.
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onDecrement) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    // m2-03 review finding 11: explicit minimum hit region,
                    // visual glyph size unchanged.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            VStack(spacing: 0) {
                Text(repsText)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("reps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 28)
            Button(action: onIncrement) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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
        .accessibilityValue(reps.map { "\($0)" } ?? "not set")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIncrement()
            case .decrement: onDecrement()
            @unknown default: break
            }
        }
    }

    private var repsText: String {
        reps.map { "\($0)" } ?? "–"
    }
}

#Preview {
    RepsControlView(reps: 8, onIncrement: {}, onDecrement: {}, onAdjustSteps: { _ in })
}

#Preview("Unset") {
    RepsControlView(reps: nil, onIncrement: {}, onDecrement: {}, onAdjustSteps: { _ in })
}
