// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Mid-session edits ... Ellipsis menu on the logging screen: add
// set / remove empty set, skip exercise, swap exercise ..., add exercise
// ..., reorder (move up/down), end workout."
//
// A full-screen sheet of plain, identifier-tappable rows rather than a
// native `Menu` -- watchOS `Menu` items are their own presentation layer
// and do not reliably surface stable accessibility identifiers to XCUITest
// (the house rule this repo runs on, per BurlyWatchUITests.swift), and a
// list of large rows is, if anything, a better fit than a compact menu for
// this app's large-target, no-fiddly-interactions house style.
//
// Discard is still posted to `pendingAction` and fired from the sheet's
// `onDismiss` -- see `LoggingScreenView`'s doc; that single dismiss-then-
// present handoff (this sheet -> `DiscardConfirmView`) has been reliably
// green across every re-run since m2-03 review round 3's fix.
//
// Swap/add are different (m2-03 review round 3, final pass): they used to
// go through that same `pendingAction`/`onDismiss` handoff into a second
// top-level sheet, and a live accessibility-tree investigation caught it
// failing intermittently in exactly the shape SwiftUI/watchOS is known to
// be unreliable at -- dismissing one system presentation and immediately
// presenting another. Converting that second presentation from
// `.sheet(item:)` to `.sheet(isPresented:)` (matching discard's shape)
// measurably reduced the failure rate but did not eliminate it: it still
// failed once in a full `acceptance-sim.sh` gate run after passing two
// isolated re-runs. The dispatcher's fix (this round): stop chaining a
// second *system* presentation for swap/add entirely. `NavigationLink
// (value:)` / `.navigationDestination(for:)` below pushes
// `ExercisePickerView` onto THIS sheet's own already-presented
// `NavigationStack` -- a plain in-stack navigation transition, not a new
// sheet, so there is no dismiss-then-present race to lose. Selecting an
// exercise (or Cancel) closes the whole sheet directly
// (`isPresented = false`), landing back on the logging screen exactly as
// the old top-level-sheet picker did.
import SwiftUI

struct SessionActionsView: View {
    let viewModel: SessionViewModel
    @Binding var isPresented: Bool
    @Binding var pendingAction: PendingSessionAction?

    var body: some View {
        NavigationStack {
            List {
                actionRow("Add set", identifier: "sessionActions.addSet") {
                    viewModel.addSetOnCurrent()
                }
                .disabled(viewModel.currentItemID == nil)

                actionRow("Remove empty set", identifier: "sessionActions.removeEmptySet") {
                    viewModel.removeEmptySetOnCurrent()
                }
                .disabled(!viewModel.canRemoveEmptySetOnCurrent)

                actionRow("Skip exercise", identifier: "sessionActions.skipExercise") {
                    viewModel.skipCurrentExercise()
                }
                .disabled(viewModel.currentItemID == nil)

                swapExerciseRow

                NavigationLink(value: ExercisePickerContext.add) {
                    Text("Add exercise")
                }
                .accessibilityIdentifier("sessionActions.addExercise")

                actionRow("Move up", identifier: "sessionActions.moveUp") {
                    viewModel.moveCurrentUp()
                }
                .disabled(!viewModel.canMoveCurrentUp)

                actionRow("Move down", identifier: "sessionActions.moveDown") {
                    viewModel.moveCurrentDown()
                }
                .disabled(!viewModel.canMoveCurrentDown)

                actionRow("End workout", identifier: "sessionActions.endWorkout") {
                    viewModel.requestEndWorkout()
                }

                actionRow("Discard workout", identifier: "sessionActions.discardWorkout", role: .destructive) {
                    pendingAction = .requestDiscard
                    isPresented = false
                }
            }
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
            .navigationDestination(for: ExercisePickerContext.self) { context in
                ExercisePickerView(
                    context: context,
                    exercises: viewModel.availableExercises(),
                    onSelect: { exerciseID in
                        switch context {
                        case .swap(let itemID):
                            viewModel.swap(currentItem: itemID, to: exerciseID)
                        case .add:
                            viewModel.addExercise(exerciseID)
                        }
                        isPresented = false
                    },
                    onAddPlaceholder: {
                        viewModel.addPlaceholderExercise()
                        isPresented = false
                    },
                    onCancel: { isPresented = false }
                )
            }
        }
    }

    /// Disabled (no current item to swap) renders as a plain, non-tappable
    /// row rather than a `NavigationLink` -- there is no valid
    /// `ExercisePickerContext.swap` to push to without an item id.
    @ViewBuilder
    private var swapExerciseRow: some View {
        if let currentID = viewModel.currentItemID {
            NavigationLink(value: ExercisePickerContext.swap(itemID: currentID)) {
                Text("Swap exercise")
            }
            .accessibilityIdentifier("sessionActions.swapExercise")
        } else {
            Text("Swap exercise")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sessionActions.swapExercise")
        }
    }

    /// Fires `action`, then dismisses -- except "Discard workout" above,
    /// which already sets `isPresented = false` itself so it can also stash
    /// `pendingAction` first. Swap/add exercise are `NavigationLink`s, not
    /// `actionRow`s -- they push rather than dismiss (see this file's doc).
    private func actionRow(
        _ title: String,
        identifier: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
            if isPresented { isPresented = false }
        } label: {
            Text(title)
        }
        .accessibilityIdentifier(identifier)
    }
}
