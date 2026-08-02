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
// this app's large-target, no-fiddly-interactions house style. Actions
// that open a further presentation (swap/add picker, discard confirm) are
// posted to `pendingAction` rather than fired directly -- see
// `LoggingScreenView`'s doc on why.
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

                actionRow("Swap exercise", identifier: "sessionActions.swapExercise") {
                    if let id = viewModel.currentItemID {
                        pendingAction = .openPicker(.swap(itemID: id))
                    }
                    isPresented = false
                }
                .disabled(viewModel.currentItemID == nil)

                actionRow("Add exercise", identifier: "sessionActions.addExercise") {
                    pendingAction = .openPicker(.add)
                    isPresented = false
                }

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
        }
    }

    /// Fires `action`, then dismisses -- except the two entries above that
    /// already set `isPresented = false` themselves so they can also stash
    /// a `pendingAction` first.
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
