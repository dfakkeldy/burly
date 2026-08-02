// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 ellipsis "swap exercise" / "add exercise": "catalog picker:
// recents -> curated -> customs; search is scribble/dictation only, never
// required." This is the flat MVP of that picker -- one alphabetical list
// (the store's own sort order) plus `.searchable`, which on watchOS is
// itself scribble/dictation-only input, so "search is optional, never a
// keyboard" falls out of the platform for free. Sectioning into
// recents/curated/customs is deliberately deferred: it is presentation
// polish on top of an already-correct, already-tested mutation
// (`SessionMutator.swapExercise` / `.addExercise`), not a behavior this
// task's acceptance criteria depend on.
//
// m2-03 review round 3 (final pass): this view no longer wraps itself in
// its own `NavigationStack`. It is plain content meant to be hosted inside
// a caller-provided one -- `SessionActionsView` pushes it as a
// `.navigationDestination(for: ExercisePickerContext.self)` (a plain
// in-stack navigation push, never a second system presentation chained off
// another sheet's dismissal -- see that file's doc for why), and
// `LoggingScreenView`'s standalone "empty session" entry point wraps it in
// its own `NavigationStack` at the call site instead.
import SwiftUI
import BurlyCore

struct ExercisePickerView: View {
    let context: ExercisePickerContext
    let exercises: [ExerciseData]
    let onSelect: (UUID) -> Void
    let onAddPlaceholder: () -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    private var filtered: [ExerciseData] {
        guard !searchText.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if case .add = context {
                Button("Custom (name later)", action: onAddPlaceholder)
                    .accessibilityIdentifier("exercisePicker.addPlaceholder")
            }
            ForEach(filtered) { exercise in
                Button(exercise.name) { onSelect(exercise.id) }
                    .accessibilityIdentifier("exercisePicker.row.\(exercise.name)")
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
    }

    private var title: String {
        switch context {
        case .swap: "Swap exercise"
        case .add: "Add exercise"
        }
    }
}

#Preview {
    NavigationStack {
        ExercisePickerView(
            context: .add,
            exercises: [
                ExerciseData(name: "Back Squat", muscleGroups: [.quads, .glutes], origin: .curated),
                ExerciseData(name: "Barbell Bench Press", muscleGroups: [.chest, .triceps], origin: .curated)
            ],
            onSelect: { _ in },
            onAddPlaceholder: {},
            onCancel: {}
        )
    }
}
