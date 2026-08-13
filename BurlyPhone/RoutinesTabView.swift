// SPDX-License-Identifier: GPL-3.0-or-later
// Phone routine authoring (spec §9): a manually ordered routine list, a
// whole-routine editor, and the small on-device exercise catalog. Persistence
// work is routed through PhoneHomeViewModel, never performed by a view.

import BurlyCore
import SwiftUI

@MainActor
struct RoutinesTabView: View {
    let viewModel: PhoneHomeViewModel

    @State private var navigationPath: [UUID] = []
    @State private var showsRoutineCreator = false
    @State private var showsCatalog = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Routines")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Catalog", systemImage: "square.grid.2x2") {
                            showsCatalog = true
                        }
                        .accessibilityIdentifier("routinesTab.catalogButton")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New routine", systemImage: "plus") {
                            showsRoutineCreator = true
                        }
                        .accessibilityIdentifier("routinesTab.newRoutineButton")
                    }
                    if !viewModel.routineRows.isEmpty {
                        ToolbarItem(placement: .bottomBar) {
                            EditButton()
                                .accessibilityIdentifier("routinesTab.editOrderButton")
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { routineID in
                    if let routine = viewModel.routineRows.first(where: { $0.id == routineID }) {
                        RoutineEditorView(
                            routine: routine,
                            viewModel: viewModel,
                            onArchive: { navigationPath.removeAll() }
                        )
                    } else {
                        ContentUnavailableView(
                            "Routine unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("This routine may have been archived in another window.")
                        )
                        .accessibilityIdentifier("routineEditor.unavailable")
                    }
                }
        }
        .task { viewModel.loadRoutinesForDisplay() }
        .sheet(isPresented: $showsRoutineCreator) {
            RoutineCreationView { name in
                do {
                    let routine = try viewModel.createRoutine(named: name)
                    showsRoutineCreator = false
                    navigationPath.append(routine.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showsCatalog) {
            NavigationStack {
                CatalogBrowserView(viewModel: viewModel)
            }
        }
        .alert("Couldn’t update routines", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.routinesState {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn’t load routines",
                message: message,
                identifierPrefix: "routinesTab",
                onRetry: { viewModel.loadRoutinesForDisplay() }
            )
        case .loaded:
            if !viewModel.hasRoutines {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: "No routines yet",
                    message: "Create a routine, then add exercises from the catalog.",
                    identifierPrefix: "routinesTab"
                )
            } else if viewModel.routineRows.isEmpty {
                ProgressView()
            } else {
                List {
                    ForEach(viewModel.routineRows) { routine in
                        Button {
                            navigationPath.append(routine.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(routine.name)
                                    .font(.headline)
                                    .accessibilityIdentifier("routinesTab.routineRow.\(routine.id.uuidString)")
                                Text("\(routine.items.count) exercise\(routine.items.count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("routinesTab.openRoutine.\(routine.id.uuidString)")
                    }
                    .onMove { offsets, destination in
                        do {
                            try viewModel.reorderRoutines(from: offsets, to: destination)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier("routinesTab.routineList")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

@MainActor
private struct RoutineCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine name") {
                    TextField("e.g. Upper body", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("routineCreator.nameField")
                }
            }
            .navigationTitle("New Routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("routineCreator.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onCreate(name) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("routineCreator.createButton")
                }
            }
        }
    }
}

@MainActor
private struct RoutineEditorView: View {
    let routine: RoutineData
    let viewModel: PhoneHomeViewModel
    let onArchive: () -> Void

    @State private var name: String
    @State private var items: [RoutineItemData]
    @State private var showsCatalog = false
    @State private var confirmsArchive = false
    @State private var errorMessage: String?

    init(routine: RoutineData, viewModel: PhoneHomeViewModel, onArchive: @escaping () -> Void) {
        self.routine = routine
        self.viewModel = viewModel
        self.onArchive = onArchive
        _name = State(initialValue: routine.name)
        _items = State(initialValue: routine.items.sorted { $0.order < $1.order })
    }

    var body: some View {
        Form {
            Section("Routine") {
                TextField("Routine name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("routineEditor.nameField.\(routine.id.uuidString)")
            }

            Section("Exercises") {
                if items.isEmpty {
                    Text("Add an exercise from the catalog to begin.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("routineEditor.emptyExercises")
                }
                ForEach($items) { $item in
                    RoutineEditorItemRow(
                        item: $item,
                        items: $items,
                        exerciseName: exerciseName(for: item.exerciseID),
                        viewModel: viewModel
                    )
                }
                .onDelete { offsets in
                    let ids = offsets.map { items[$0].id }
                    for id in ids {
                        items = viewModel.removingRoutineItem(id: id, from: items)
                    }
                }
                .onMove { offsets, destination in
                    items = viewModel.movedRoutineItems(items, from: offsets, to: destination)
                }

                Button("Add exercise", systemImage: "plus") {
                    showsCatalog = true
                }
                .accessibilityIdentifier("routineEditor.addExerciseButton")
            }

            Section {
                Button("Save routine") {
                    do {
                        try viewModel.saveRoutine(id: routine.id, name: name, items: items)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("routineEditor.saveButton")
            }

            Section {
                Button("Archive routine", systemImage: "archivebox", role: .destructive) {
                    confirmsArchive = true
                }
                .accessibilityIdentifier("routineEditor.archiveButton")
            }
        }
        .navigationTitle("Edit Routine")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityIdentifier("routineEditor.editItemsButton")
            }
        }
        .task { viewModel.loadCatalogForDisplay() }
        .sheet(isPresented: $showsCatalog) {
            NavigationStack {
                CatalogBrowserView(viewModel: viewModel) { exercise in
                    items.append(viewModel.newRoutineItem(for: exercise.id, after: items))
                    showsCatalog = false
                }
            }
        }
        .confirmationDialog("Archive this routine?", isPresented: $confirmsArchive, titleVisibility: .visible) {
            Button("Archive routine", role: .destructive) {
                do {
                    try viewModel.archiveRoutine(id: routine.id)
                    onArchive()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("routineEditor.confirmArchiveButton")
        } message: {
            Text("Past workouts will stay in your history.")
        }
        .alert("Couldn’t save routine", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func exerciseName(for id: UUID?) -> String {
        guard let id else { return "Archived exercise" }
        return viewModel.catalogExercises.first(where: { $0.id == id })?.name ?? "Archived exercise"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

@MainActor
private struct RoutineEditorItemRow: View {
    @Binding var item: RoutineItemData
    @Binding var items: [RoutineItemData]

    let exerciseName: String
    let viewModel: PhoneHomeViewModel

    var body: some View {
        let itemID: UUID = item.id
        let canMoveUp: Bool = item.order > 0
        let canMoveDown: Bool = item.order < items.count - 1

        // No row-level .accessibilityIdentifier here (m2-03): stamping one
        // on this container clobbered RoutineItemEditorRow's own leaf
        // identifiers (exerciseName, set-count, restMenu, move buttons),
        // the same collapse fixed in CatalogBrowserView's row above.
        RoutineItemEditorRow(
            item: $item,
            exerciseName: exerciseName,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            onAdjustSetCount: { delta in
                item = viewModel.adjustedRoutineItem(
                    item,
                    setCountDelta: delta
                )
            },
            onSelectRest: { rest in
                item = viewModel.restOverriddenRoutineItem(
                    item,
                    with: rest
                )
            },
            onMoveUp: {
                items = viewModel.movingRoutineItem(id: itemID, by: -1, in: items)
            },
            onMoveDown: {
                items = viewModel.movingRoutineItem(id: itemID, by: 1, in: items)
            }
        )
    }
}

@MainActor
private struct RoutineItemEditorRow: View {
    @Binding var item: RoutineItemData
    let exerciseName: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onAdjustSetCount: (Int) -> Void
    let onSelectRest: (TimeInterval?) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exerciseName)
                .font(.headline)
                .accessibilityIdentifier("routineEditor.exerciseName.\(item.id.uuidString)")

            HStack {
                Button {
                    onAdjustSetCount(-1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled(item.defaultSetCount <= 1)
                .accessibilityIdentifier("routineEditor.decreaseSetCount.\(item.id.uuidString)")

                Text("\(item.defaultSetCount) sets")
                    .monospacedDigit()
                    .accessibilityIdentifier("routineEditor.itemSetCount.\(item.id.uuidString)")

                Button {
                    onAdjustSetCount(1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityIdentifier("routineEditor.increaseSetCount.\(item.id.uuidString)")

                Spacer()

                Menu {
                    Button("Use default rest") { onSelectRest(nil) }
                    Button("60 sec") { onSelectRest(60) }
                    Button("90 sec") { onSelectRest(90) }
                    Button("120 sec") { onSelectRest(120) }
                } label: {
                    Text(restLabel)
                }
                .accessibilityIdentifier("routineEditor.restMenu.\(item.id.uuidString)")
            }

            HStack {
                Button("Move up", systemImage: "arrow.up") { onMoveUp() }
                    .disabled(!canMoveUp)
                    .accessibilityIdentifier("routineEditor.moveUp.\(item.id.uuidString)")
                Button("Move down", systemImage: "arrow.down") { onMoveDown() }
                    .disabled(!canMoveDown)
                    .accessibilityIdentifier("routineEditor.moveDown.\(item.id.uuidString)")
            }
            .font(.subheadline)
        }
        // Form's automatic button style can promote sibling controls to a
        // shared row action. Keep set and move controls independently tappable.
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private var restLabel: String {
        guard let rest = item.restOverride else { return "Default rest" }
        return "\(Int(rest)) sec rest"
    }
}

@MainActor
private struct CatalogBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: PhoneHomeViewModel
    var onSelect: ((ExerciseData) -> Void)? = nil

    @State private var showsCustomCreator = false
    @State private var archiveCandidate: ExerciseData?
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        Group {
            switch viewModel.catalogState {
            case .loading:
                ProgressView()
            case .failed(let message):
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn’t load catalog",
                    message: message,
                    identifierPrefix: "catalog",
                    onRetry: { viewModel.loadCatalogForDisplay() }
                )
            case .loaded:
                List(filteredExercises) { exercise in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name)
                                .font(.headline)
                                .accessibilityIdentifier("catalog.exerciseName.\(exercise.id.uuidString)")
                            Text(exercise.muscleGroups.map(\.displayName).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("catalog.exerciseTags.\(exercise.id.uuidString)")
                        }
                        Spacer(minLength: 4)
                        if let onSelect {
                            Button("Add") { onSelect(exercise) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("catalog.addExercise.\(exercise.id.uuidString)")
                        }
                        Button(role: .destructive) {
                            archiveCandidate = exercise
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .accessibilityLabel("Archive \(exercise.name)")
                        .accessibilityIdentifier("catalog.archiveExercise.\(exercise.id.uuidString)")
                    }
                    // Add and archive are separate actions in the same List row.
                    .buttonStyle(.borderless)
                    .padding(.vertical, 3)
                    // No row-level .accessibilityIdentifier here (m2-03):
                    // stamping an identifier on this plain HStack container
                    // clobbered every descendant's own identifier (name,
                    // tags, add, and archive all reported back the row's
                    // identifier instead of their own), making
                    // catalog.addExercise.* / catalog.archiveExercise.*
                    // unreachable. Leaving the container unidentified lets
                    // each leaf control keep its own.
                }
                .accessibilityIdentifier("catalog.exerciseList")
            }
        }
        .navigationTitle(onSelect == nil ? "Exercise Catalog" : "Add Exercise")
        .searchable(text: $searchText, prompt: "Search exercises")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("catalog.doneButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Custom exercise", systemImage: "plus") {
                    showsCustomCreator = true
                }
                .accessibilityIdentifier("catalog.newCustomExerciseButton")
            }
        }
        .task { viewModel.loadCatalogForDisplay() }
        .sheet(isPresented: $showsCustomCreator) {
            CustomExerciseCreationView { name, tags in
                do {
                    _ = try viewModel.createCustomExercise(named: name, muscleGroups: tags)
                    showsCustomCreator = false
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Archive \(archiveCandidate?.name ?? "exercise")?",
            isPresented: Binding(
                get: { archiveCandidate != nil },
                set: { if !$0 { archiveCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive exercise", role: .destructive) {
                guard let candidate = archiveCandidate else { return }
                do {
                    try viewModel.archiveExercise(id: candidate.id)
                    archiveCandidate = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("catalog.confirmArchiveButton")
        } message: {
            Text("Archived exercises stay available in past workout history.")
        }
        .alert("Couldn’t update catalog", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var filteredExercises: [ExerciseData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.catalogExercises }
        return viewModel.catalogExercises.filter { exercise in
            exercise.name.localizedCaseInsensitiveContains(query)
                || exercise.muscleGroups.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
    }
}

@MainActor
private struct CustomExerciseCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedGroups: Set<MuscleGroup> = []

    let onCreate: (String, [MuscleGroup]) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise name") {
                    TextField("e.g. Cable curl", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("catalog.custom.nameField")
                }
                Section("Muscle groups") {
                    ForEach(MuscleGroup.allCases, id: \.self) { group in
                        Button {
                            if selectedGroups.contains(group) {
                                selectedGroups.remove(group)
                            } else {
                                selectedGroups.insert(group)
                            }
                        } label: {
                            HStack {
                                Text(group.displayName)
                                Spacer()
                                if selectedGroups.contains(group) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityIdentifier("catalog.custom.muscleTag.\(group.rawValue)")
                        .accessibilityValue(selectedGroups.contains(group) ? "Selected" : "Not selected")
                    }
                }
            }
            .navigationTitle("Custom Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("catalog.custom.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, MuscleGroup.allCases.filter(selectedGroups.contains))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedGroups.isEmpty)
                    .accessibilityIdentifier("catalog.custom.createButton")
                }
            }
        }
    }
}

private extension MuscleGroup {
    var displayName: String {
        switch self {
        case .upperBack: "Upper back"
        case .chest: "Chest"
        case .lats: "Lats"
        case .shoulders: "Shoulders"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .glutes: "Glutes"
        case .calves: "Calves"
        case .core: "Core"
        }
    }
}

#Preview {
    RoutinesTabView(viewModel: .previewLoaded)
}
