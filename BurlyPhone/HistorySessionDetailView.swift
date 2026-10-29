// SPDX-License-Identifier: GPL-3.0-or-later

import BurlyCore
import SwiftUI

@MainActor
struct HistorySessionDetailView: View {
    let viewModel: PhoneHomeViewModel
    @State private var session: SessionData
    @State private var pickerPresented = false
    @State private var errorMessage: String?
    @State private var notesDraft: String
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
                                    mutate { session in
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
                        HStack {
                            Text(exerciseName(for: item))
                                .accessibilityIdentifier("historyDetail.exercise.\(exerciseIdentifier(for: item))")
                            Spacer()
                            Button("Remove", role: .destructive) {
                                mutate { value in value.items.removeAll { $0.id == item.id }; reindexItems(&value) }
                            }
                            .accessibilityIdentifier("historyDetail.removeExercise.\(exerciseIdentifier(for: item))")
                        }
                    }
                }
                .onMove { source, destination in
                    mutate { value in
                        var sorted = value.items.sorted { $0.order < $1.order }
                        sorted.move(fromOffsets: source, toOffset: destination)
                        value.items = sorted
                        reindexItems(&value)
                    }
                }
            }
            Section("Notes") {
                TextField("Notes", text: $notesDraft, axis: .vertical)
                .accessibilityIdentifier("historyDetail.notes")
                Button("Save notes") {
                    mutate { $0.notes = notesDraft.isEmpty ? nil : notesDraft }
                }
                .accessibilityIdentifier("historyDetail.saveNotes")
            }
        }
        .navigationTitle(session.routineName ?? "Workout")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add exercise", systemImage: "plus") { pickerPresented = true }
                    .accessibilityIdentifier("historyDetail.addExercise")
                EditButton()
                    .accessibilityIdentifier("historyDetail.reorderExercises")
            }
        }
        .sheet(isPresented: $pickerPresented) {
            ExercisePicker(exercises: viewModel.historyExercises) { exercise in
                mutate { value in
                    value.items.append(SessionItemData(exerciseID: exercise.id, order: value.items.count))
                }
                pickerPresented = false
            }
        }
        .alert("Couldn’t save edit", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func exerciseName(for item: SessionItemData) -> String {
        guard let id = item.exerciseID else { return "Exercise" }
        return viewModel.historyExercises.first(where: { $0.id == id })?.name ?? "Exercise"
    }

    private func exerciseIdentifier(for item: SessionItemData) -> String {
        item.exerciseID?.uuidString ?? "unattributed"
    }

    private func mutate(_ change: (inout SessionData) -> Void) {
        var updated = session
        change(&updated)
        do { session = try viewModel.saveHistoryEdit(updated) }
        catch { errorMessage = String(describing: error) }
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
    let onSave: (SetRecordData) -> Void
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
    @FocusState private var focusedField: Field?

    init(set: SetRecordData, unit: WeightUnit, onSave: @escaping (SetRecordData) -> Void) {
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
                    guard let newWeight = enteredWeight, let repetitions = Int(reps), repetitions >= 0 else { return }
                    var updated = set
                    updated.setWeight(newWeight)
                    updated.reps = repetitions
                    updated.isWarmup = isWarmup
                    onSave(updated)
                    dismiss()
                }
                .accessibilityIdentifier("historyDetail.saveSet")
            }
        }
    }

    /// The weight to store, or `nil` when the text is not a weight (Save
    /// then does nothing, as before).
    private var enteredWeight: Weight? {
        if weight == initialWeightText { return set.weight }
        return entryUnit.parse(weight)
    }
}

private struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [ExerciseData]
    let select: (ExerciseData) -> Void
    var body: some View {
        NavigationStack {
            List(exercises) { exercise in
                Button(exercise.name) { select(exercise); dismiss() }
                    .accessibilityIdentifier("historyDetail.exercisePicker.\(exercise.id.uuidString)")
            }
            .navigationTitle("Add exercise")
        }
    }
}

@MainActor
struct NamingQueueView: View {
    let viewModel: PhoneHomeViewModel
    let placeholder: ExerciseData
    @State private var name: String
    @State private var errorMessage: String?

    init(viewModel: PhoneHomeViewModel, placeholder: ExerciseData) {
        self.viewModel = viewModel
        self.placeholder = placeholder
        _name = State(initialValue: placeholder.name)
    }

    var body: some View {
        Form {
            Section("Name this exercise") {
                TextField("Exercise name", text: $name).accessibilityIdentifier("namingQueue.nameField")
                Button("Save name") {
                    do { try viewModel.namePlaceholder(placeholder, as: name) }
                    catch { errorMessage = String(describing: error) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("namingQueue.saveName")
            }
            Section("Or merge into") {
                ForEach(viewModel.historyExercises.filter { $0.id != placeholder.id }) { exercise in
                    Button(exercise.name) {
                        do { try viewModel.mergePlaceholder(placeholder, into: exercise) }
                        catch { errorMessage = String(describing: error) }
                    }
                    .accessibilityIdentifier("namingQueue.merge.\(exercise.id.uuidString)")
                }
            }
        }
        .navigationTitle("Name exercise")
        .alert("Couldn’t update exercise", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
