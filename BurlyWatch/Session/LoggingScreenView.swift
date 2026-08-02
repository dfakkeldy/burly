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
/// presentation (the swap/add picker, the discard confirmation). SwiftUI
/// cannot reliably present a second sheet/dialog while the first is still
/// dismissing, so these are deferred to the actions sheet's `onDismiss`
/// rather than fired while it's still on screen -- see `LoggingScreenView
/// .body`.
enum PendingSessionAction: Equatable {
    case openPicker(ExercisePickerContext)
    case requestDiscard
}

struct LoggingScreenView: View {
    @State private var viewModel: SessionViewModel
    @State private var isShowingActions = false
    @State private var pendingAction: PendingSessionAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    init(engine: SessionEngine, store: BurlyStore) {
        _viewModel = State(initialValue: SessionViewModel(engine: engine, store: store))
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
        // m2-03 review round 3 (final pass): ground truth (a live
        // accessibility-tree dump around `testPlaceholderExerciseCreate
        // FailureBlocksAndRetrySucceeds`) showed the ellipsis sheet
        // dismissing cleanly and its "Add exercise" row's own action
        // firing (`pendingAction` set, `isPresented` false), but this
        // sheet never presenting afterward -- reproducibly, across
        // multiple settle-delay lengths, so not a timing issue. The
        // sibling `.sheet(isPresented: discardConfirmBinding)` above,
        // driven by the exact same `onDismiss -> pendingAction` handoff,
        // presents reliably every time. The one structural difference is
        // `.sheet(item:)` vs `.sheet(isPresented:)` -- so this now uses
        // the same already-proven `isPresented`-driven shape, reading
        // `viewModel.pickerContext` directly inside the content closure
        // instead of relying on `item:`'s captured-value semantics.
        .sheet(isPresented: isShowingPickerBinding) {
            if let context = viewModel.pickerContext {
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
        case .openPicker(let context):
            viewModel.pickerContext = context
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
