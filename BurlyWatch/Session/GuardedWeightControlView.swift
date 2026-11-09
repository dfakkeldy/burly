// SPDX-License-Identifier: MIT
// Spec §2 "Guarded weight edit (the deliberate-gesture arm)". The UI layer
// over `GuardedWeightEditMachine` (BurlyCore) -- this view holds no lock
// logic of its own; every state transition is asked of `SessionViewModel`,
// which asks the engine. What lives here is purely: how locked/armed
// *looks*, the long-press gesture that arms it, and the crown/micro-button
// wiring that only does anything while armed (the machine also refuses an
// `.adjust` while locked, so this is belt-and-suspenders, not the only
// guard).
//
// Weight is displayed in the phone's unit (sync snapshot schema 2, via the
// `watchSettings` environment) through `WeightUnit.formattedNumber` and
// its symbol, one decimal place, display only -- the engine's `Weight`
// stays canonical kg and is never re-parsed from this text.
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
    @Environment(\.watchSettings) private var settings
    /// One width for both lock glyphs: `lock.open.fill` is about 5 pt wider
    /// than `lock.fill` at this size, and arming used to take those points
    /// from the number. Leading-aligned, so the lock's body stays put and
    /// only the shackle opens.
    @ScaledMetric(relativeTo: .caption) private var lockWidth: CGFloat = 15

    /// The number big, its unit small underneath, so the control fits
    /// beside reps on a 42 mm screen; the number shrinks before it would
    /// truncate. The ±micro-buttons are `GuardedWeightAdjustButtons`, which
    /// stand in for the reps control beside this one while armed (see
    /// `ExercisePageView`).
    ///
    /// On 42 mm a locked 100.0 already draws at a bit under 0.6 of its
    /// size, so the scale may go to 0.4: a six-character weight (1102.5 lb,
    /// 1000.0 lb) needs about 0.46 there. At 0.6, the old floor, the open
    /// lock's extra width was enough to truncate an armed 100.0 to "10…",
    /// and at 0.5 a 1102.5 lb still truncated. No numeric content
    /// transition: no weight change runs in an animation, so it never
    /// animated.
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isArmed ? "lock.open.fill" : "lock.fill")
                .font(.caption)
                .foregroundStyle(isArmed ? Color.accentColor : .secondary)
                .frame(width: lockWidth, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(numberText)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(settings.displayUnit.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isArmed ? Color.accentColor : .primary)
        }
        // m2-03 review finding 11: the long-press-to-arm gesture's parent
        // only had 4 points of vertical padding above; an explicit minimum
        // frame gives the arm gesture a real 44×44 hit region without
        // changing how the control looks. It also takes the whole column
        // beside reps, so the long press lands anywhere in it.
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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

    /// Honest placeholder while unset and untouched (m2-03 review finding
    /// 3) -- once armed, the control is showing a real, editable number
    /// (0 lb by default, same as any other weight), so the dash only
    /// applies to the locked, never-yet-armed state.
    private var numberText: String {
        guard isUnset, !isArmed else {
            return settings.displayUnit.formattedNumber(weight)
        }
        return "–"
    }

    private var accessibilityValueText: String {
        let lockWord = isArmed ? "armed" : "locked"
        guard isUnset, !isArmed else {
            return "\(settings.displayUnit.formatted(weight)), \(lockWord)"
        }
        return "not set, \(lockWord)"
    }
}

/// §2 "Armed: ... +/− micro-buttons appear": one step of the configured
/// increment per tap. Shown only while the weight is armed, in the reps
/// control's place, in the armed weight's accent colour; the engine
/// refuses an adjustment while locked anyway. Two 44 pt buttons at the
/// ends of whatever width they are given (`ExercisePageView` gives them
/// the reps control's), so − and + sit where reps' − and + were.
struct GuardedWeightAdjustButtons: View {
    let onAdjustSteps: (Int) -> Void

    /// Their width with no reps control to match: two 44 pt buttons 28 pt
    /// apart, about the reps control's own.
    static let fallbackWidth: CGFloat = 116

    var body: some View {
        HStack(spacing: 0) {
            Button { onAdjustSteps(-1) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    // m2-03 review finding 11: explicit minimum hit
                    // region, visual glyph size unchanged.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Decrease weight")
            Spacer(minLength: 28)
            Button { onAdjustSteps(1) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Increase weight")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
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
