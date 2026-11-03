// SPDX-License-Identifier: GPL-3.0-or-later

import BurlyCore
import SwiftUI

@MainActor
struct HistorySessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PhoneHomeViewModel
    @State private var session: SessionData
    @State private var pickerPresented = false
    @State private var errorMessage: String?
    @State private var notesDraft: String
    /// Removing an exercise drops every set under it, so it asks first.
    @State private var removeCandidate: SessionItemData?
    @State private var confirmingDelete = false
    #if DEBUG
    // Exercise the existing error path against a synthetic UI-test store.
    // Never enabled for the real store or included in release builds.
    @State private var failNextSaveForUITest =
        ProcessInfo.processInfo.environment["BURLY_PHONE_UI_TEST_SCENARIO"] == "populated"
        && ProcessInfo.processInfo.environment["BURLY_PHONE_UI_TEST_FAIL_HISTORY_SAVE_ONCE"] == "1"
    #endif
    /// Spec §9 #2: set rows render in the Settings display unit.
    @AppStorage(DisplayUnitPreference.storageKey) private var unit = DisplayUnitPreference.defaultUnit

    init(viewModel: PhoneHomeViewModel, session: SessionData) {
        self.viewModel = viewModel
        _session = State(initialValue: session)
        _notesDraft = State(initialValue: session.notes ?? "")
    }

    var body: some View {
        List {
            #if DEBUG
            Text("Revision \(session.revision)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("historyDetail.revision.\(session.revision)")
            if let healthKitWorkoutID = session.healthKitWorkoutID {
                Text("HealthKit workout \(healthKitWorkoutID.uuidString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyDetail.healthKitWorkout.\(healthKitWorkoutID.uuidString)")
            }
            #endif
            Section("Exercises") {
                ForEach(session.items.sorted { $0.order < $1.order }) { item in
                    Section {
                        ForEach(item.sets.sorted { $0.order < $1.order }) { set in
                            NavigationLink {
                                HistorySetEditor(set: set, unit: unit) { updated in
                                    try commitMutation { session in
                                        guard let itemIndex = session.items.firstIndex(where: { $0.id == item.id }),
                                              let setIndex = session.items[itemIndex].sets.firstIndex(where: { $0.id == updated.id }) else { return }
                                        session.items[itemIndex].sets[setIndex] = updated
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("\(unit.formatted(set.weight)) × \(set.reps)")
                                    Spacer()
                                    if set.isWarmup { Text("Warmup").foregroundStyle(.secondary) }
                                }
                            }
                            .accessibilityIdentifier("historyDetail.set.\(set.id.uuidString)")
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    mutate { session in
                                        guard let itemIndex = session.items.firstIndex(where: { $0.id == item.id }) else { return }
                                        session.items[itemIndex].sets.removeAll { $0.id == set.id }
                                        reindexSets(&session.items[itemIndex])
                                    }
                                }
                                .accessibilityIdentifier("historyDetail.removeSet.\(set.id.uuidString)")
                            }
                        }
                        .onMove { source, destination in
                            mutate { session in
                                guard let itemIndex = session.items.firstIndex(where: { $0.id == item.id }) else { return }
                                var sets = session.items[itemIndex].sets.sorted { $0.order < $1.order }
                                sets.move(fromOffsets: source, toOffset: destination)
                                session.items[itemIndex].sets = sets
                                reindexSets(&session.items[itemIndex])
                            }
                        }
                        Button("Add set", systemImage: "plus") {
                            mutate { session in
                                guard let index = session.items.firstIndex(where: { $0.id == item.id }) else { return }
                                let sets = session.items[index].sets
                                session.items[index].sets.append(SetRecordData(order: sets.count, weight: .bodyweight, reps: 0, completedAt: .now))
                            }
                        }
                        .accessibilityIdentifier("historyDetail.addSet.\(item.id.uuidString)")
                    } header: {
                        // Exercise order moves one step per tap. A List
                        // gives drag handles to rows, never to Sections, so
                        // an `.onMove` on this ForEach of Sections was never
                        // called; explicit buttons, like the routine editor
                        // uses, are the reorder that actually works.
                        HStack {
                            Text(exerciseName(for: item))
                                .accessibilityIdentifier("historyDetail.exercise.\(exerciseIdentifier(for: item))")
                            Spacer()
                            Button {
                                moveItem(item, by: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(isFirst(item))
                            .accessibilityLabel("Move \(exerciseName(for: item)) up")
                            .accessibilityIdentifier("historyDetail.moveExerciseUp.\(item.id.uuidString)")
                            Button {
                                moveItem(item, by: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(isLast(item))
                            .accessibilityLabel("Move \(exerciseName(for: item)) down")
                            .accessibilityIdentifier("historyDetail.moveExerciseDown.\(item.id.uuidString)")
                            Button("Remove", role: .destructive) {
                                removeCandidate = item
                            }
                            .accessibilityIdentifier("historyDetail.removeExercise.\(exerciseIdentifier(for: item))")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Notes") {
                TextField("Notes", text: $notesDraft, axis: .vertical)
                .accessibilityIdentifier("historyDetail.notes")
                Button("Save notes") {
                    mutate { $0.notes = draftNotes }
                }
                // Nothing to save until the text differs from what is
                // stored: an unchanged save is not an edit (provenance
                // honesty, §6).
                .disabled(draftNotes == session.notes)
                .accessibilityIdentifier("historyDetail.saveNotes")
            }
            Section {
                Button("Delete Workout", role: .destructive) {
                    confirmingDelete = true
                }
                .accessibilityIdentifier("historyDetail.deleteSession")
            }
        }
        .navigationTitle(session.routineName ?? "Workout")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add exercise", systemImage: "plus") { pickerPresented = true }
                    .accessibilityIdentifier("historyDetail.addExercise")
                // Edit mode reorders sets within an exercise (their rows'
                // `.onMove`); exercises move with their header buttons.
                EditButton()
                    .accessibilityIdentifier("historyDetail.reorderSets")
            }
        }
        .sheet(isPresented: $pickerPresented) {
            ExercisePicker(exercises: viewModel.historyExercises.filter { $0.archivedAt == nil && !$0.needsNaming }) { exercise in
                mutate { value in
                    value.items.append(SessionItemData(exerciseID: exercise.id, order: value.items.count))
                }
                pickerPresented = false
            }
        }
        .confirmationDialog(
            "Remove \(removeCandidate.map(exerciseName(for:)) ?? "exercise")?",
            isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } }),
            titleVisibility: .visible,
            presenting: removeCandidate
        ) { item in
            Button("Remove Exercise", role: .destructive) {
                mutate { value in value.items.removeAll { $0.id == item.id }; reindexItems(&value) }
                removeCandidate = nil
            }
            .accessibilityIdentifier("historyDetail.confirmRemoveExercise")
        } message: { item in
            Text(removalMessage(for: item))
        }
        .confirmationDialog(
            "Delete this workout?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Workout", role: .destructive) {
                do {
                    try viewModel.deleteHistorySession(session)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("historyDetail.confirmDeleteSession")
        } message: {
            Text(HistorySessionDeletion.confirmationMessage(for: session))
        }
        .alert("Couldn’t save edit", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// The notes field as it would be stored: empty text clears the note.
    private var draftNotes: String? {
        notesDraft.isEmpty ? nil : notesDraft
    }

    private func removalMessage(for item: SessionItemData) -> String {
        switch item.sets.count {
        case 0: "It has no sets logged in this workout."
        case 1: "Its 1 set is removed from this workout."
        default: "Its \(item.sets.count) sets are removed from this workout."
        }
    }

    private func isFirst(_ item: SessionItemData) -> Bool {
        session.items.min { $0.order < $1.order }?.id == item.id
    }

    private func isLast(_ item: SessionItemData) -> Bool {
        session.items.max { $0.order < $1.order }?.id == item.id
    }

    /// Swaps `item` with its neighbour `offset` (±1) places away, then
    /// renumbers. The end buttons are disabled, so a move is never a no-op.
    private func moveItem(_ item: SessionItemData, by offset: Int) {
        mutate { value in
            var sorted = value.items.sorted { $0.order < $1.order }
            guard let source = sorted.firstIndex(where: { $0.id == item.id }),
                  sorted.indices.contains(source + offset) else { return }
            sorted.swapAt(source, source + offset)
            value.items = sorted
            reindexItems(&value)
        }
    }

    private func exerciseName(for item: SessionItemData) -> String {
        guard let id = item.exerciseID else { return "Exercise" }
        return viewModel.historyExercises.first(where: { $0.id == id })?.name ?? "Exercise"
    }

    private func exerciseIdentifier(for item: SessionItemData) -> String {
        item.exerciseID?.uuidString ?? "unattributed"
    }

    private func mutate(_ change: (inout SessionData) -> Void) {
        do { try commitMutation(change) }
        catch { errorMessage = error.localizedDescription }
    }

    private func commitMutation(_ change: (inout SessionData) -> Void) throws {
        var updated = session
        change(&updated)
        // A save that changes nothing is not an edit: it must not bump the
        // revision or mark a sensor-true session as edited (§6 provenance
        // honesty). Checked before the DEBUG failure seam, so an untouched
        // save never consumes the one injected failure.
        guard updated != session else { return }
        #if DEBUG
        if failNextSaveForUITest {
            failNextSaveForUITest = false
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
        session = try viewModel.saveHistoryEdit(updated)
    }

    private func reindexItems(_ session: inout SessionData) {
        for index in session.items.indices { session.items[index].order = index }
    }

    private func reindexSets(_ item: inout SessionItemData) {
        for index in item.sets.indices { item.sets[index].order = index }
    }
}

/// Edits one logged set. The weight field speaks the Settings display unit
/// in both directions (spec §9 #2): it starts as the stored kg converted
/// into that unit, and Save parses the text back through the same unit —
/// a lifter in lb mode who types 180 stores 81.6466… kg, not 180 kg (the
/// trap planning task m5-05 records against the old `Weight(kg:
/// Double(text))` parse).
private struct HistorySetEditor: View {
    private enum Field: Hashable {
        case weight
        case reps
    }

    @Environment(\.dismiss) private var dismiss
    let set: SetRecordData
    let onSave: (SetRecordData) throws -> Void
    /// Latched for the editor's lifetime, not read live. The parent
    /// re-creates this view whenever it re-renders (including after a unit
    /// change made in the Settings tab while this screen stays pushed), but
    /// `@State weight` keeps the text the user saw. Holding the unit in
    /// `@State` too keeps the label, the text, and the Save parse in one
    /// unit, so a mid-edit switch can never re-read lb text as kg.
    @State private var entryUnit: WeightUnit
    /// The field's starting text. Saving it untouched keeps the stored
    /// weight exactly: re-parsing a rounded display value would quietly
    /// move 90 kg to 89.99 kg in lb mode (Weight.swift: display rounding
    /// must never round-trip back into kg).
    @State private var initialWeightText: String
    @State private var weight: String
    @State private var reps: String
    @State private var isWarmup: Bool
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(set: SetRecordData, unit: WeightUnit, onSave: @escaping (SetRecordData) throws -> Void) {
        self.set = set
        self.onSave = onSave
        let text = unit.formattedNumber(set.weight)
        _entryUnit = State(initialValue: unit)
        _initialWeightText = State(initialValue: text)
        _weight = State(initialValue: text)
        _reps = State(initialValue: String(set.reps))
        _isWarmup = State(initialValue: set.isWarmup)
    }

    var body: some View {
        Form {
            TextField("Weight (\(entryUnit.symbol))", text: $weight)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .weight)
                .accessibilityIdentifier("historyDetail.setWeight")
            TextField("Reps", text: $reps)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .reps)
                .accessibilityIdentifier("historyDetail.setReps")
            Toggle("Warmup", isOn: $isWarmup).accessibilityIdentifier("historyDetail.setWarmup")
        }
        .navigationTitle("Edit set")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let newWeight = enteredWeight, let repetitions = enteredReps else { return }
                    var updated = set
                    updated.setWeight(newWeight)
                    updated.reps = repetitions
                    updated.isWarmup = isWarmup
                    do {
                        try onSave(updated)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                // Disabled rather than a silent no-op: text Save cannot
                // read (including ambiguous "1,000", which parse refuses)
                // must look unsaveable instead of appearing to ignore the
                // tap (review finding on the settings branch).
                .disabled(enteredWeight == nil || enteredReps == nil)
                .accessibilityIdentifier("historyDetail.saveSet")
            }
        }
        .alert("Couldn’t save edit", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The weight to store, or `nil` when the text is not a weight (Save
    /// is then disabled).
    private var enteredWeight: Weight? {
        if weight == initialWeightText { return set.weight }
        return entryUnit.parse(weight)
    }

    /// The rep count to store, or `nil` when the text is not one.
    private var enteredReps: Int? {
        guard let repetitions = Int(reps), repetitions >= 0 else { return nil }
        return repetitions
    }
}

/// The confirmation copy for deleting a logged session, shared by the
/// History row's swipe action and the detail screen's button so both say
/// the same thing about what happens to the Apple Health copy.
enum HistorySessionDeletion {
    static func confirmationMessage(for session: SessionData) -> String {
        let burly = "This removes the workout and all its sets from Burly's history and stats. This can't be undone."
        guard session.healthKitWorkoutID != nil else { return burly }
        return burly + " Burly will also ask Apple Health to delete its copy. If it can't, you can delete it in the Health app."
    }
}

extension ExerciseData {
    /// The catalog browser's search rule (name or muscle tag), for the
    /// History pickers that list the same ~100-exercise catalog.
    func matchesExerciseSearch(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query)
            || muscleGroups.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
    }
}

private struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [ExerciseData]
    let select: (ExerciseData) -> Void
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(exercises.filter { $0.matchesExerciseSearch(searchText) }) { exercise in
                Button(exercise.name) { select(exercise); dismiss() }
                    .accessibilityIdentifier("historyDetail.exercisePicker.\(exercise.id.uuidString)")
            }
            .navigationTitle("Add exercise")
            .searchable(text: $searchText, prompt: "Search exercises")
        }
    }
}

@MainActor
struct NamingQueueView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PhoneHomeViewModel
    let placeholder: ExerciseData
    @State private var name: String
    /// Collected with the name: the watch creates placeholders untagged,
    /// and an untagged exercise counts as unattributed in the muscle split.
    @State private var muscleGroups: Set<MuscleGroup>
    @State private var searchText = ""
    @State private var mergeCandidate: ExerciseData?
    @State private var errorMessage: String?

    init(viewModel: PhoneHomeViewModel, placeholder: ExerciseData) {
        self.viewModel = viewModel
        self.placeholder = placeholder
        _name = State(initialValue: placeholder.name)
        _muscleGroups = State(initialValue: Set(placeholder.muscleGroups))
    }

    var body: some View {
        Form {
            Section("Name this exercise") {
                TextField("Exercise name", text: $name).accessibilityIdentifier("namingQueue.nameField")
            }
            MuscleGroupTagPicker(selection: $muscleGroups, identifierPrefix: "namingQueue.muscleTag")
            Section("Or merge into an existing exercise") {
                // A filter field in the section rather than `.searchable`:
                // an active search controller hides this screen's toolbar,
                // and with it Save.
                TextField("Search exercises", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("namingQueue.mergeSearch")
                ForEach(mergeTargets) { exercise in
                    Button(exercise.name) { mergeCandidate = exercise }
                        .accessibilityIdentifier("namingQueue.merge.\(exercise.id.uuidString)")
                }
            }
        }
        .navigationTitle("Name exercise")
        .toolbar {
            // In the bar rather than under the twelve tags, so it stays in
            // reach with the keyboard up. Closes on success, so the banner
            // can offer the next placeholder (its link is keyed by
            // placeholder id, so the next one opens with fresh state).
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try viewModel.namePlaceholder(placeholder, as: name, muscleGroups: muscleGroups.inTaxonomyOrder)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || muscleGroups.isEmpty)
                .accessibilityIdentifier("namingQueue.saveName")
            }
        }
        .confirmationDialog(
            "Merge into \(mergeCandidate?.name ?? "exercise")?",
            isPresented: Binding(get: { mergeCandidate != nil }, set: { if !$0 { mergeCandidate = nil } }),
            titleVisibility: .visible,
            presenting: mergeCandidate
        ) { destination in
            Button("Merge") {
                do {
                    try viewModel.mergePlaceholder(placeholder, into: destination)
                    mergeCandidate = nil
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("namingQueue.confirmMerge")
        } message: { destination in
            Text("Every set logged as “\(placeholder.name)” moves to \(destination.name). This can't be undone.")
        }
        .alert("Couldn’t update exercise", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// Real, current exercises only: never this placeholder, an archived
    /// exercise, or another unnamed placeholder (merging into one would
    /// just move the problem).
    private var mergeTargets: [ExerciseData] {
        viewModel.historyExercises.filter { exercise in
            exercise.id != placeholder.id
                && exercise.archivedAt == nil
                && !exercise.needsNaming
                && exercise.matchesExerciseSearch(searchText)
        }
    }
}
