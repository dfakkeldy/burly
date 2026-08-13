// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Logging screen (one exercise at a time, TabView paging
// vertical)": header, ghost row, weight + reps controls, one primary
// full-width Log set button, and the §3 rest-timer hosting seam. One of
// these exists per `SessionItemData` in the `TabView`.
//
// The ghost row and header are pure per-item reads (`SessionViewModel
// .ghost(for:)` etc.) so a neighbouring page mid-swipe still shows its own
// numbers. The interactive weight/reps/Log controls only render for
// whichever item is `currentItemID` -- the guarded weight control and the
// rest timer are each one shared value on the engine (§2/§3), not one per
// item, so they are only meaningful on the page that is actually current.
import SwiftUI
import BurlyCore

struct ExercisePageView: View {
    let viewModel: SessionViewModel
    let item: SessionItemData

    private var isCurrent: Bool { item.id == viewModel.currentItemID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                ghostRow
                if isCurrent {
                    interactiveControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.exerciseName(item.exerciseID))
                .font(.headline)
                .lineLimit(2)
                // The vertical pager deliberately presents one item at a
                // time. Its ordinal makes that rendered sequence available
                // to VoiceOver (and proves a move-up/down changed the
                // screen's order without relying on an ambiguous first
                // matching row in UI tests).
                .accessibilityValue(
                    "Exercise \(viewModel.renderedItemOrdinal(for: item.id) ?? 0) of \(viewModel.items.count)"
                )
                .accessibilityIdentifier(currentIdentifier("exercisePage.name"))
            Text(setCounterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(currentIdentifier("exercisePage.setCounter"))
        }
    }

    private var setCounterText: String {
        let logged = viewModel.loggedSetCount(for: item.id)
        let planned = viewModel.plannedSetCount(for: item.id)
        let displayIndex = min(logged + 1, max(planned, 1))
        return "Set \(displayIndex) of \(planned)"
    }

    private var ghostRow: some View {
        Text(ghostText)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier(currentIdentifier("exercisePage.ghost"))
    }

    /// §2 acceptance #5: a seeded digest renders "Last: <weight> × <reps>"
    /// for this set index; an absent one renders a plain, non-crashing,
    /// non-numeric placeholder -- never a stale or fabricated number.
    private var ghostText: String {
        guard let ghost = viewModel.ghost(for: item.id) else { return "No previous data" }
        let pounds = (ghost.weight.pounds * 2).rounded() / 2
        return String(format: "Last: %.1f lb × %d", pounds, ghost.reps)
    }

    /// A `TabView` keeps neighbouring pages in the accessibility tree.
    /// The current page retains the stable test-facing identifier; inactive
    /// siblings carry their item UUID so no query accidentally pairs a
    /// control from one page with a label from another.
    private func currentIdentifier(_ base: String) -> String {
        isCurrent ? base : "\(base).\(item.id.uuidString)"
    }

    @ViewBuilder
    private var interactiveControls: some View {
        VStack(spacing: 10) {
            GuardedWeightControlView(
                weight: viewModel.currentWeight,
                isArmed: viewModel.isWeightArmed,
                isUnset: viewModel.isWeightUnset,
                onArm: viewModel.armWeight,
                onAdjustSteps: viewModel.adjustWeight(bySteps:)
            )

            RepsControlView(
                reps: viewModel.currentReps,
                onIncrement: viewModel.incrementReps,
                onDecrement: viewModel.decrementReps,
                onAdjustSteps: viewModel.adjustReps(bySteps:)
            )

            // §2: "one primary full-width Log set button." Also the
            // Double Tap primary action (SessionViewModel.logCurrentSet's
            // doc) -- one call site for both an on-screen tap and the
            // watchOS Double Tap gesture. Disabled while there is nothing
            // honest to log yet (m2-03 review finding 3): an honestly-empty
            // prefill must not be logged as an invented bodyweight×8 just
            // because Double Tap fired.
            Button(action: viewModel.logCurrentSet) {
                Text("Log set")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .handGestureShortcut(.primaryAction)
            .disabled(!viewModel.canLogCurrentSet)
            .accessibilityIdentifier("logSetButton")

            if viewModel.isRestRunning, let restTimer = viewModel.restTimer {
                RestTimerBanner(
                    timer: restTimer,
                    onAdjust: viewModel.adjustRest(by:),
                    onSkip: viewModel.skipRest
                )
            }
        }
    }
}
