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
//
// `isUnset` (m2-03 review finding 3): true when the §2 prefill ladder came
// back `.empty` and the lifter has not armed-and-adjusted a real value yet.
// The engine's `WeightEditState` always holds a concrete `Weight` (0 kg,
// the same substrate `.bodyweight` uses) -- there is no "no weight"
// representation there without a BurlyCore change, out of this task's
// scope. So this view renders the honest placeholder itself rather than
// presenting that internal zero as if it were real prefill data.
import SwiftUI
import BurlyCore

struct GuardedWeightControlView: View {
    let weight: Weight
    let isArmed: Bool
    let isUnset: Bool
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
                    Button { onAdjustSteps(-1) } label: {
                        Image(systemName: "minus")
                            // m2-03 review finding 11: explicit minimum hit
                            // region, visual glyph size unchanged.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Decrease weight")
                    Button { onAdjustSteps(1) } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Increase weight")
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        // m2-03 review finding 11: the long-press-to-arm gesture's parent
        // only had 4 points of vertical padding above; an explicit minimum
        // frame gives the arm gesture a real 44×44 hit region without
        // changing how the control looks.
        .frame(minHeight: 44)
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

    /// Honest placeholder while unset and untouched (m2-03 review finding
    /// 3) -- once armed, the control is showing a real, editable number
    /// (0 lb by default, same as any other weight), so the dash only
    /// applies to the locked, never-yet-armed state.
    private var weightText: String {
        guard isUnset, !isArmed else {
            return String(format: "%.1f lb", displayPounds)
        }
        return "– lb"
    }

    private var accessibilityValueText: String {
        let lockWord = isArmed ? "armed" : "locked"
        guard isUnset, !isArmed else {
            return "\(String(format: "%.1f lb", displayPounds)), \(lockWord)"
        }
        return "not set, \(lockWord)"
    }
}

#Preview("Locked") {
    GuardedWeightControlView(weight: Weight(kg: 60), isArmed: false, isUnset: false, onArm: {}, onAdjustSteps: { _ in })
}

#Preview("Armed") {
    GuardedWeightControlView(weight: Weight(kg: 60), isArmed: true, isUnset: false, onArm: {}, onAdjustSteps: { _ in })
}

#Preview("Unset") {
    GuardedWeightControlView(weight: Weight(kg: 0), isArmed: false, isUnset: true, onArm: {}, onAdjustSteps: { _ in })
}
