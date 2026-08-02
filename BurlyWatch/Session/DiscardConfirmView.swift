// SPDX-License-Identifier: GPL-3.0-or-later
// §2 Discard: "destructive, double-confirm."
//
// m2-03 review round 3 (final pass): this used to be a single
// `.confirmationDialog` on `LoggingScreenView` whose `isPresented` binding
// never went false between the two steps, with its title/actions computed
// from which step was active (round B's fix for the two-separate-dialogs
// defect that preceded it). That still failed the same way, live-tested
// twice: `SaveFailureUITests.testDiscardFailureBlocksAndRetrySucceeds`
// never saw "Discard permanently" appear after tapping "Discard," even
// though the binding never toggled off. The conclusion (also backed by a
// documented SwiftUI/watchOS limitation): `.confirmationDialog` does not
// reliably re-diff its title/actions builder while already presented --
// it renders once at presentation time.
//
// The fix here is structural, not another confirmationDialog variant: a
// dedicated full-screen confirm view, modeled on `SessionConflictView`
// (which has no presentation-chaining problem to begin with, since it only
// ever shows one step). `LoggingScreenView` presents this ONCE via a plain
// `.sheet(isPresented:)`; moving from step one's content to step two's is
// just this view's own body re-rendering from `viewModel`'s already-
// `@Observable` flags -- ordinary SwiftUI content diffing inside an
// already-presented sheet, not a second system presentation.
import SwiftUI

struct DiscardConfirmView: View {
    let viewModel: SessionViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("discardConfirm.heading")

                if viewModel.isShowingDiscardStepTwo {
                    Text("Every logged set in this workout will be permanently deleted.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Discard permanently", role: .destructive, action: viewModel.confirmDiscardStepTwo)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("discardConfirm.stepTwoButton")
                } else {
                    Text("This workout's sets will be lost.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Discard", role: .destructive, action: viewModel.confirmDiscardStepOne)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("discardConfirm.stepOneButton")
                }

                Button("Cancel", role: .cancel, action: viewModel.cancelDiscard)
                    .accessibilityIdentifier("discardConfirm.cancelButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private var heading: String {
        viewModel.isShowingDiscardStepTwo ? "This can't be undone." : "Discard this workout?"
    }
}
