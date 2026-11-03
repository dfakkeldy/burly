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
//
// ## Compact on purpose
//
// Everything needed to log a set must be on screen when the page opens,
// with no crown turn first: the 46 mm screen leaves about 190 pt under the
// navigation bar, the 42 mm one about 165 pt. So the set counter and ghost
// row share one subtitle line under a one-line name (wrapping to two lines
// only when they do not fit side by side), and weight and reps sit side by
// side with their units underneath. Every tap target stays 44 pt.
//
// The page does not grow under Log set while the lifter is using it: the
// armed weight's -/+ take the reps control's place in the same row. A
// running rest scrolls the controls row to the top of the screen, so the
// controls, Log set and the countdown are all in view and nothing sits
// under the clock or the ellipsis button.
import SwiftUI
import BurlyCore

struct ExercisePageView: View {
    let viewModel: SessionViewModel
    let item: SessionItemData

    @Environment(\.watchSettings) private var settings

    /// The pending scroll to the controls, if any. A lifter's own scroll
    /// cancels it, so a delayed retry never pulls the page back.
    @State private var revealTask: Task<Void, Never>?

    private var isCurrent: Bool { item.id == viewModel.currentItemID }

    private static let controlsRowID = "exercisePage.controlsRow"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    if isCurrent {
                        interactiveControls
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            // Only a scroll of the lifter's own cancels a pending reveal. A
            // touch that has not moved (`.tracking`) is also the Log set
            // tap that started the rest; cancelling on it could lose the
            // reveal.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    revealTask?.cancel()
                }
            }
            // §3: the countdown sits "near the Log button area" and must be
            // visible once a set is logged. The banner is the last row, below
            // Log set, so it can start partly off screen; bring it in
            // whenever a new rest starts. `startedAt` changes only on a new
            // rest, so ±15 and skip do not move the page.
            //
            // Every reveal waits for the tap or page turn that caused it to
            // settle, then tries once more; a second scroll to the same
            // place does nothing. Run at once, a reveal after Log set never
            // came, or came seconds late, on the hosted simulator, and one
            // during a page turn stopped short (17 of 42 pt on 46 mm).
            .onChange(of: viewModel.restTimer?.startedAt) { _, startedAt in
                guard isCurrent, startedAt != nil else { return }
                revealRest(proxy, after: Self.settleDelays)
            }
            // The same for a rest already running when this page becomes
            // the current one (paging during a rest) or first appears
            // (Resume mid-rest).
            .onChange(of: isCurrent) { _, nowCurrent in
                guard nowCurrent, viewModel.isRestRunning else { return }
                revealRest(proxy, after: Self.settleDelays)
            }
            .onAppear {
                guard isCurrent, viewModel.isRestRunning else { return }
                revealRest(proxy, after: Self.settleDelays)
            }
        }
    }

    private static let settleDelays: [Duration] = [.milliseconds(450), .milliseconds(700)]

    /// Scrolls the controls row to the top of the visible area, just under
    /// the navigation bar: the header goes out of view, and weight and reps,
    /// Log set and the countdown fill the screen. Anchoring the banner's
    /// bottom instead put the weight and reps row under the clock and the
    /// ellipsis button, so the top of reps + opened the actions sheet.
    private func revealRest(_ proxy: ScrollViewProxy, after delays: [Duration]) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, isCurrent, viewModel.isRestRunning else { return }
                withAnimation {
                    proxy.scrollTo(Self.controlsRowID, anchor: .top)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.exerciseName(item.exerciseID))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("exercisePage.name")
                .accessibilityValue(ordinalText)
            // One line when the counter and the ghost fit side by side at
            // full size, two otherwise. Only the chosen layout is drawn, so
            // each identifier still names exactly one element. On two lines
            // each shrinks a little, then truncates, rather than running
            // past the bezel at larger text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    setCounter.fixedSize()
                    ghostRow.fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    setCounter
                    ghostRow
                }
            }
        }
    }

    private var setCounter: some View {
        Text(setCounterText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier("exercisePage.setCounter")
    }

    /// The pager shows one exercise at a time; this tells VoiceOver (and the
    /// UI tests) where this one sits in the visible order, which is what a
    /// skip, move or add changes. Empty for a page mid-removal.
    private var ordinalText: String {
        guard let ordinal = viewModel.pageOrdinal(for: item.id) else { return "" }
        return "Exercise \(ordinal) of \(viewModel.items.count)"
    }

    /// "Set 2 of 3" while sets remain, then "All 3 sets logged": a counter
    /// that kept reading "Set 3 of 3" after the third set looked as if one
    /// were still owed.
    private var setCounterText: String {
        let logged = viewModel.loggedSetCount(for: item.id)
        let planned = viewModel.plannedSetCount(for: item.id)
        guard logged < planned else {
            return logged == 1 ? "1 set logged" : "All \(logged) sets logged"
        }
        return "Set \(logged + 1) of \(planned)"
    }

    private var ghostRow: some View {
        Text(ghostText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier("exercisePage.ghost")
    }

    /// §2 acceptance #5: a seeded digest renders "Last: <weight> × <reps>"
    /// for this set index; an absent one renders a plain, non-crashing,
    /// non-numeric placeholder -- never a stale or fabricated number.
    private var ghostText: String {
        guard let ghost = viewModel.ghost(for: item.id) else { return "No previous data" }
        return "Last: \(settings.displayUnit.formatted(ghost.weight)) × \(ghost.reps)"
    }

    @ViewBuilder
    private var interactiveControls: some View {
        VStack(spacing: 4) {
            // Weight takes what width is left and shrinks its number to
            // fit; reps keeps its two 44 pt buttons.
            HStack(alignment: .center, spacing: 4) {
                GuardedWeightControlView(
                    weight: viewModel.currentWeight,
                    isArmed: viewModel.isWeightArmed,
                    isUnset: viewModel.isWeightUnset,
                    onArm: viewModel.armWeight,
                    onAdjustSteps: viewModel.adjustWeight(bySteps:)
                )

                // §2: "Armed: ... +/− micro-buttons appear." They take the
                // reps control's place while the weight is armed, so the
                // row keeps its height and Log set stays where it was. They
                // are narrower than reps, so the number being changed never
                // has less room than it had locked. The arm ends at the
                // next Log set, a page change or 3 s idle, and reps come
                // back.
                if viewModel.isWeightArmed {
                    GuardedWeightAdjustButtons(onAdjustSteps: viewModel.adjustWeight(bySteps:))
                        .layoutPriority(1)
                        .transition(.opacity)
                } else {
                    RepsControlView(
                        reps: viewModel.currentReps,
                        onIncrement: viewModel.incrementReps,
                        onDecrement: viewModel.decrementReps,
                        onAdjustSteps: viewModel.adjustReps(bySteps:)
                    )
                    .layoutPriority(1)
                }
            }
            .id(Self.controlsRowID)

            // §2: "one primary full-width Log set button." Also the
            // Double Tap primary action (SessionViewModel.logCurrentSet's
            // doc) -- one call site for both an on-screen tap and the
            // watchOS Double Tap gesture. Disabled while there is nothing
            // honest to log yet (m2-03 review finding 3): an honestly-empty
            // prefill must not be logged as an invented bodyweight×8 just
            // because Double Tap fired. The label's minimum is below the
            // bordered style's own height, which measured 48 pt on the 42 mm
            // simulator and 52.5 pt on the 46 mm one.
            Button(action: viewModel.logCurrentSet) {
                Text("Log set")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
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
