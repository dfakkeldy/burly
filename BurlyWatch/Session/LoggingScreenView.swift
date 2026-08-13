// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2: the real logging screen that replaces SessionStartStubView.
// Hosts the exercise pager, the ellipsis menu's mid-session edits, the
// swap/add picker sheet, and the Finish/Keep going/Discard summary flow.
// Everything here is routing and presentation; every rule is
// `SessionViewModel` calling into the already-tested BurlyCore engine.
import SwiftUI
import BurlyCore
import BurlyPersistence

/// An action from the §2 ellipsis sheet that itself opens another
/// presentation. SwiftUI cannot reliably present a second sheet/dialog
/// while the first is still dismissing, so this is deferred to the actions
/// sheet's `onDismiss` rather than fired while it's still on screen -- see
/// `LoggingScreenView.body`.
///
/// m2-03 review round 3 (final pass): this used to also carry
/// `.openPicker(ExercisePickerContext)` for the swap/add flow, which shared
/// this exact dismiss-then-present handoff into a second top-level sheet.
/// That handoff was the confirmed, if intermittent, root cause of
/// `SaveFailureUITests.testPlaceholderExerciseCreateFailureBlocksAndRetry
/// Succeeds`'s flake. Swap/add no longer go through `pendingAction` at all
/// -- `SessionActionsView` now pushes the picker onto its own
/// already-presented `NavigationStack` directly (see that file's doc) --
/// so only the one remaining chained presentation (discard) is left here,
/// and it has been reliably green.
enum PendingSessionAction: Equatable {
    case requestDiscard
}

struct LoggingScreenView: View {
    @State private var viewModel: SessionViewModel
    @State private var isShowingActions = false
    @State private var pendingAction: PendingSessionAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// - Parameter startInSummary: threaded straight through to
    ///   `SessionViewModel.init` -- see its doc. m2-06's Resume-decline path
    ///   (`SessionEntryView`'s `.resume(sessionID:enterSummary: true)`)
    ///   is the only caller that passes `true`.
    init(engine: SessionEngine, store: BurlyStore, startInSummary: Bool = false) {
        _viewModel = State(initialValue: SessionViewModel(engine: engine, store: store, startInSummary: startInSummary))
    }

    var body: some View {
        Group {
            // m2-03 review findings 6-9: a blocking save failure takes
            // priority over everything else on screen -- the lifter cannot
            // be allowed to keep logging, end the workout, or navigate away
            // while a mutation's durability is still in question.
            if let saveFailure = viewModel.saveFailure {
                SaveFailureView(message: saveFailure, onRetry: viewModel.retrySave)
            } else if let finished = viewModel.finishedSummary {
                SessionSummaryView(
                    summary: finished,
                    isFinal: true,
                    isFinishing: false,
                    saveError: nil,
                    onFinish: {},
                    onRetryFinish: {},
                    onKeepGoing: {},
                    onDiscard: {},
                    onDone: { dismiss() }
                )
            } else if let preview = viewModel.endWorkoutPreview {
                SessionSummaryView(
                    summary: preview,
                    isFinal: false,
                    isFinishing: viewModel.isFinishing,
                    saveError: viewModel.finishSaveError,
                    onFinish: viewModel.commitFinish,
                    onRetryFinish: viewModel.retryFinishSave,
                    onKeepGoing: viewModel.keepGoing,
                    onDiscard: viewModel.requestDiscard,
                    onDone: {}
                )
            } else {
                loggingBody
            }
        }
        .sheet(isPresented: $isShowingActions, onDismiss: applyPendingAction) {
            SessionActionsView(
                viewModel: viewModel,
                isPresented: $isShowingActions,
                pendingAction: $pendingAction
            )
        }
        // m2-03 review round 3 (final pass): the ellipsis-menu route to the
        // swap/add picker no longer goes through this sheet at all --
        // `SessionActionsView` pushes it directly onto its own
        // `NavigationStack` (see that file's doc for the full history: a
        // live accessibility-tree investigation caught the previous
        // dismiss-then-present chain into a second top-level sheet failing
        // intermittently, and the fix was to stop chaining a second system
        // presentation entirely, not to keep tuning which sheet API drives
        // it).
        //
        // This sheet now serves ONLY the "empty session" entry point below
        // (`emptySessionPlaceholder`'s own "Add exercise" button, which
        // sets `viewModel.pickerContext` directly from the plain logging
        // screen -- never from within another sheet's dismissal, so it was
        // never part of the chained-presentation defect and doesn't need
        // to change). `ExercisePickerView` no longer wraps itself in a
        // `NavigationStack` (it's shared with the pushed-destination use
        // above), so this call site supplies one.
        .sheet(isPresented: isShowingPickerBinding) {
            if let context = viewModel.pickerContext {
                NavigationStack {
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
                        },
                        onAddPlaceholder: viewModel.addPlaceholderExercise,
                        onCancel: { viewModel.pickerContext = nil }
                    )
                }
            }
        }
        // §2 Discard: "destructive, double-confirm."
        //
        // Round C fix (m2-03 review, final pass): rounds A/B both tried
        // `.confirmationDialog` shapes -- first two separate dialogs
        // (broken: SwiftUI cannot reliably chain a second presentation
        // right after the first dismisses), then one dialog whose
        // `isPresented` binding never toggles off between steps, with
        // title/actions computed from which step is active (still broken,
        // confirmed live: `SaveFailureUITests
        // .testDiscardFailureBlocksAndRetrySucceeds` never saw "Discard
        // permanently" appear -- `.confirmationDialog` does not reliably
        // re-diff its content while already presented). This drops
        // `.confirmationDialog` entirely: `DiscardConfirmView` is a
        // dedicated full-screen confirm view (modeled on
        // `SessionConflictView`, which has no chaining problem because it
        // only ever shows one step) presented ONCE via a plain `.sheet`.
        // Moving from step one's content to step two's is ordinary body
        // diffing inside an already-presented sheet, not a second system
        // presentation.
        .sheet(isPresented: discardConfirmBinding) {
            DiscardConfirmView(viewModel: viewModel)
        }
        // §2 Always-On: the screen actually woke from the dimmed state --
        // feeds §3's "repeats once at +5 s if screen never woke."
        .onChange(of: isLuminanceReduced) { wasReduced, isReduced in
            if wasReduced && !isReduced {
                viewModel.noteScreenWake()
            }
        }
        .onChange(of: viewModel.didDiscard) { _, discarded in
            if discarded { dismiss() }
        }
    }

    @ViewBuilder
    private var loggingBody: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if viewModel.items.isEmpty {
                    emptySessionPlaceholder
                } else {
                    TabView(selection: viewModel.pagingSelection) {
                        ForEach(viewModel.items) { item in
                            ExercisePageView(viewModel: viewModel, item: item)
                                .tag(item.id as UUID?)
                        }
                    }
                    .tabViewStyle(.verticalPage)
                }
            }
            // §2 Always-On: "1 Hz TimelineView." The tick itself is the
            // side effect hook, not the render -- see `SessionViewModel
            // .tick()`'s doc.
            .onChange(of: context.date) { _, _ in viewModel.tick() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("ellipsisMenu")
                .accessibilityLabel("Workout actions")
            }
        }
    }

    private var emptySessionPlaceholder: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Add an exercise to begin")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Add exercise") { viewModel.pickerContext = .add }
                    .accessibilityIdentifier("emptySession.addExercise")
                Button("End workout", action: viewModel.requestEndWorkout)
                    .accessibilityIdentifier("emptySession.endWorkout")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func applyPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .requestDiscard:
            viewModel.requestDiscard()
        }
    }

    // MARK: - Bindings

    private var isShowingPickerBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pickerContext != nil },
            set: { if !$0 { viewModel.pickerContext = nil } }
        )
    }

    /// True across both discard steps -- kept `true` continuously while
    /// `confirmDiscardStepOne()` flips which step is active, so the single
    /// `.sheet` above never dismisses and re-presents; `DiscardConfirmView`
    /// re-renders its own content from `viewModel`'s flags instead (see its
    /// doc comment and `LoggingScreenView.body`'s).
    private var discardConfirmBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingDiscardStepOne || viewModel.isShowingDiscardStepTwo },
            set: { if !$0 { viewModel.cancelDiscard() } }
        )
    }
}
