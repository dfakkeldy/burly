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
            if let finished = viewModel.finishedSummary {
                SessionSummaryView(
                    summary: finished,
                    isFinal: true,
                    isFinishing: false,
                    onFinish: {},
                    onKeepGoing: {},
                    onDiscard: {},
                    onDone: { dismiss() }
                )
            } else if let preview = viewModel.endWorkoutPreview {
                SessionSummaryView(
                    summary: preview,
                    isFinal: false,
                    isFinishing: viewModel.isFinishing,
                    onFinish: viewModel.commitFinish,
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
        .sheet(item: pickerContextBinding) { context in
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
        // §2 Discard: "destructive, double-confirm."
        .confirmationDialog(
            "Discard this workout?",
            isPresented: discardStepOneBinding,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: viewModel.confirmDiscardStepOne)
            Button("Cancel", role: .cancel, action: viewModel.cancelDiscard)
        }
        .confirmationDialog(
            "This can't be undone.",
            isPresented: discardStepTwoBinding,
            titleVisibility: .visible
        ) {
            Button("Discard permanently", role: .destructive, action: viewModel.confirmDiscardStepTwo)
            Button("Cancel", role: .cancel, action: viewModel.cancelDiscard)
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

    private var pickerContextBinding: Binding<ExercisePickerContext?> {
        Binding(get: { viewModel.pickerContext }, set: { viewModel.pickerContext = $0 })
    }

    private var discardStepOneBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingDiscardStepOne },
            set: { if !$0 { viewModel.cancelDiscard() } }
        )
    }

    private var discardStepTwoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingDiscardStepTwo },
            set: { if !$0 { viewModel.cancelDiscard() } }
        )
    }
}
