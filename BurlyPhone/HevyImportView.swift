// SPDX-License-Identifier: GPL-3.0-or-later
// The Hevy CSV import screen (spec §8; task m7-02), replacing m5-01's
// placeholder. Reached from the welcome's "Import from Hevy" and from the
// Settings row; both present it over the tab shell (see MainTabView).
//
// Flow per §8: intro (what comes in, what is left out, that Health is not
// written again) -> "Choose CSV File" -> preview -> "Import N Workouts" ->
// progress -> summary. The preview shows every dropped-data category the
// parse reports, including the two m7-01 said must never be hidden
// (encoding damage and rows lost to an unclosed quote), and states the
// time-zone assumption the dates were read with.
//
// Accessibility: each number is one VoiceOver element ("New workouts, 3")
// whose value is also what UI tests read, so the spoken preview and the
// asserted preview are the same thing. Every container scrolls, so large
// Dynamic Type never clips an action out of reach (m5-01 review finding 7).

import SwiftUI
import UniformTypeIdentifiers
import BurlyImport
import BurlyPersistence

struct HevyImportView: View {
    @State private var model: HevyImportModel
    @State private var isPickerPresented = false
    /// Dismisses the screen (the presenter owns how).
    let onClose: () -> Void

    init(viewModel: PhoneHomeViewModel, onClose: @escaping () -> Void) {
        _model = State(initialValue: HevyImportModel(viewModel: viewModel))
        self.onClose = onClose
    }

    var body: some View {
        content
            .navigationTitle("Import from Hevy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isImporting == false && model.isFinished == false {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose)
                            .accessibilityIdentifier("hevyImport.cancelButton")
                    }
                }
            }
            // A half-written import is recoverable (re-importing is
            // idempotent), but there's no reason to invite it.
            .interactiveDismissDisabled(model.isImporting)
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await model.readFile(at: url) }
                case .failure(let error):
                    model.reportFailure(error)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .intro:
            HevyImportIntroView(onChooseFile: chooseFile)
        case .reading:
            HevyImportBusyView(title: "Reading your export…", progress: nil)
                .accessibilityIdentifier("hevyImport.reading")
        case .preview(let plan):
            HevyImportPreviewView(
                plan: plan,
                timeZoneName: model.timeZoneName,
                wasRefreshed: model.previewWasRefreshed,
                onImport: { Task { await model.importPlanned() } },
                onChooseAnother: chooseFile,
                onDone: onClose
            )
        case .importing(let written, let total):
            HevyImportBusyView(
                title: "Importing workouts…",
                progress: (written, total)
            )
            .accessibilityIdentifier("hevyImport.importing")
        case .finished(let plan, let outcome):
            HevyImportSummaryView(
                plan: plan,
                outcome: outcome,
                onRetry: { Task { await model.importPlanned() } },
                onDone: onClose
            )
        case .unrecognizedHeader(let missingColumns):
            HevyImportProblemView(
                systemImage: "doc.questionmark",
                title: "This doesn't look like a Hevy export",
                message: Self.unrecognizedHeaderMessage(missingColumns: missingColumns),
                identifier: "hevyImport.headerError",
                onChooseAnother: chooseFile
            )
        case .unreadable(let message):
            HevyImportProblemView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't read that file",
                message: "Nothing was imported. \(message)",
                identifier: "hevyImport.readError",
                onChooseAnother: chooseFile
            )
        case .historyCheckFailed(let afterPartialImport):
            HevyImportProblemView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't check your history",
                message: Self.historyCheckFailedMessage(afterPartialImport: afterPartialImport),
                identifier: "hevyImport.historyError",
                actionTitle: "Choose the File Again",
                onChooseAnother: chooseFile
            )
        }
    }

    /// The file was fine; the store read wasn't. Says what did and didn't
    /// happen, and that trying again cannot duplicate anything.
    private static func historyCheckFailedMessage(afterPartialImport: Bool) -> String {
        let what = afterPartialImport
            ? "Burly couldn't read your workout history to see what's left to import. "
                + "The workouts already added stay in History."
            : "Burly couldn't read your workout history to compare it with this file, so nothing was imported."
        return what + " Choosing the file again is safe: workouts already in Burly are skipped, never duplicated."
    }

    /// Kind and specific: names what's missing, says nothing was imported,
    /// and says what to do next.
    private static func unrecognizedHeaderMessage(missingColumns: [String]) -> String {
        let noun = missingColumns.count == 1 ? "column" : "columns"
        let list = missingColumns.joined(separator: ", ")
        return "Burly reads the workout CSV that Hevy exports. This file is missing the \(list) \(noun), "
            + "so nothing was imported. Export your workouts from Hevy again and choose that file."
    }

    /// The picker, or — in DEBUG builds launched by a UI test — the bundled
    /// synthetic export (the Files picker is not drivable by XCUITest).
    private func chooseFile() {
        #if DEBUG
        if let fixture = HevyImportUITestFixture.requestedData() {
            switch fixture {
            case .success(let data):
                Task { await model.readData(data) }
            case .failure(let error):
                model.reportFailure(error)
            }
            return
        }
        #endif
        isPickerPresented = true
    }
}

// MARK: - Intro

private struct HevyImportIntroView: View {
    let onChooseFile: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        // Decorative — the heading says the same thing.
                        .accessibilityHidden(true)
                    Text("Bring in your Hevy history")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("hevyImport.intro.heading")
                    Text("You'll see exactly what will be added before anything is saved.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                IntroPoint(
                    systemImage: "checkmark.circle",
                    title: "What comes in",
                    message: "Every workout with its exercises and sets: weights, reps and warm-ups. "
                        + "Exercises Burly doesn't know become custom exercises, so nothing goes missing."
                )
                IntroPoint(
                    systemImage: "minus.circle",
                    title: "What's left out",
                    message: "Cardio, RPE, supersets, exercise notes, and failure or drop-set markers "
                        + "(those sets come in as normal sets). The preview counts each one."
                )
                IntroPoint(
                    systemImage: "heart.text.square",
                    title: "Apple Health stays as it is",
                    message: "Burly doesn't write imported workouts to Apple Health. "
                        + "If Hevy saved them there, they're already in Health and won't be counted twice."
                )
                IntroPoint(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: "Safe to repeat",
                    message: "Importing a newer export later adds only the workouts Burly doesn't have yet."
                )

                Text("In Hevy, export your workout data as a CSV file, then choose it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: onChooseFile) {
                    Label("Choose CSV File", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("hevyImport.chooseFileButton")
            }
            .padding()
        }
    }
}

private struct IntroPoint: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Busy

private struct HevyImportBusyView: View {
    let title: String
    let progress: (done: Int, total: Int)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text(title)
                    } currentValueLabel: {
                        Text("\(progress.done) of \(progress.total)")
                            .monospacedDigit()
                    }
                } else {
                    ProgressView(title)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

private struct HevyImportPreviewView: View {
    let plan: HevyImportPlan
    let timeZoneName: String
    let wasRefreshed: Bool
    let onImport: () -> Void
    let onChooseAnother: () -> Void
    let onDone: () -> Void

    private var preview: HevyImportPreview { plan.preview }

    var body: some View {
        List {
            if wasRefreshed {
                Section {
                    Label(
                        "Your history changed while this was open, so these numbers were updated. Check them, then import.",
                        systemImage: "arrow.clockwise"
                    )
                    .accessibilityIdentifier("hevyImport.preview.refreshedNotice")
                }
            }

            if preview.isNothingNew {
                Section {
                    // `isNothingNew` is also true for a file with no workouts
                    // at all (every row unreadable, header-only, cardio-only);
                    // that is not a success and must not read as one (m7-02
                    // review). The identifier sits on the combined element:
                    // `.combine` folds its children into one accessibility
                    // element, so a child's identifier would not reach
                    // XCUITest (SessionSummaryView.summaryRow's pattern).
                    VStack(alignment: .leading, spacing: 6) {
                        if hasNoImportableWorkouts {
                            Label("No workouts Burly can import in this file", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                        } else {
                            Label("Everything in this file is already in Burly", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                        }
                        Text(nothingNewMessage)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        hasNoImportableWorkouts ? "hevyImport.preview.nothingImportable" : "hevyImport.preview.nothingNew"
                    )
                }
            }

            Section {
                CountRow(
                    title: "New workouts", systemImage: "figure.strengthtraining.traditional",
                    count: preview.newWorkoutCount, identifier: "hevyImport.preview.newWorkouts"
                )
                CountRow(
                    title: "Already in Burly", systemImage: "checkmark.circle",
                    count: preview.alreadyImportedWorkoutCount, identifier: "hevyImport.preview.alreadyImported"
                )
                CountRow(
                    title: "Sets", systemImage: "list.number",
                    count: preview.setCount, identifier: "hevyImport.preview.sets"
                )
                if let range = preview.newWorkoutDateRange ?? preview.fileDateRange {
                    ValueRow(
                        title: preview.isNothingNew ? "Dates in file" : "Dates",
                        systemImage: "calendar",
                        value: HevyImportFormat.dateRange(range),
                        identifier: "hevyImport.preview.dateRange"
                    )
                }
            } header: {
                Text("Workouts")
            } footer: {
                Text("Times read as \(timeZoneName). Hevy's export doesn't say which time zone it used, "
                    + "so Burly places workouts in this iPhone's current time zone.")
                    .accessibilityIdentifier("hevyImport.preview.timeZone")
            }

            if preview.isNothingNew == false {
                Section {
                    CountRow(
                        title: "Matched", systemImage: "link",
                        count: preview.exercisesMatched, identifier: "hevyImport.preview.exercisesMatched"
                    )
                    CountRow(
                        title: "New custom exercises", systemImage: "plus.circle",
                        count: preview.newCustomExerciseCount, identifier: "hevyImport.preview.newCustoms"
                    )
                    ForEach(Array(preview.newCustomExerciseNames.enumerated()), id: \.offset) { index, name in
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                            .accessibilityLabel("New custom exercise: \(name)")
                            .accessibilityIdentifier("hevyImport.preview.newCustomName.\(index)")
                    }
                } header: {
                    Text("Exercises")
                } footer: {
                    Text("Matched exercises are ones Burly already knows, from its catalog or an earlier import. "
                        + "The rest are added as custom exercises.")
                }
            }

            HevyImportDropReport(summary: plan.fileSummary, identifierPrefix: "hevyImport.preview")

            Section {
                if preview.isNothingNew {
                    Button(action: onDone) {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hevyImport.doneButton")
                } else {
                    Button(action: onImport) {
                        Label(importTitle, systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hevyImport.importButton")
                }
                Button(action: onChooseAnother) {
                    Text("Choose a Different File").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("hevyImport.chooseAnotherButton")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var importTitle: String {
        preview.newWorkoutCount == 1 ? "Import 1 Workout" : "Import \(preview.newWorkoutCount) Workouts"
    }

    private var hasNoImportableWorkouts: Bool {
        preview.workoutsInFile == 0
    }

    private var nothingNewMessage: String {
        let count = preview.workoutsInFile
        if count == 0 {
            return "Nothing was found to import. Anything that was set aside, and why, is listed below."
        }
        let workouts = count == 1 ? "The 1 workout" : "All \(count) workouts"
        return "\(workouts) in this file \(count == 1 ? "is" : "are") already in your history. Nothing will be added or duplicated."
    }
}

// MARK: - Dropped-data report (shared by preview and summary)

/// Every category the parse reports, zeros included, so the user can see
/// each one was checked (§8: "The import summary reports every dropped
/// count"; m7-01 carry-over: encoding damage and unclosed-quote losses are
/// never hidden, and malformed rows are listed with their reasons).
private struct HevyImportDropReport: View {
    let summary: HevyImportSummary
    let identifierPrefix: String

    private static let malformedRowDisplayLimit = 50

    private var encodingDamagedRowCount: Int {
        summary.malformedRows.filter { $0.reason == .invalidUTF8 }.count
    }

    var body: some View {
        Section {
            CountRow(
                title: "Cardio rows", systemImage: "figure.run",
                count: summary.cardioRowsSkipped, identifier: "\(identifierPrefix).drop.cardio",
                detail: "Apple Workout already tracks cardio."
            )
            CountRow(
                title: "RPE values", systemImage: "gauge.with.dots.needle.33percent",
                count: summary.rpeValuesDropped, identifier: "\(identifierPrefix).drop.rpe"
            )
            CountRow(
                title: "Superset groupings", systemImage: "link.badge.plus",
                count: summary.supersetRowsDropped, identifier: "\(identifierPrefix).drop.superset",
                detail: "Those sets come in on their own."
            )
            CountRow(
                title: "Failure and drop-set markers", systemImage: "flag",
                count: summary.nonStandardSetTypeMarkersFlattened, identifier: "\(identifierPrefix).drop.setTypeMarkers",
                detail: "Those sets come in as normal sets."
            )
            CountRow(
                title: "Exercise notes", systemImage: "note.text",
                count: summary.exerciseNotesDropped, identifier: "\(identifierPrefix).drop.exerciseNotes"
            )
            CountRow(
                title: "Hevy set numbers", systemImage: "number",
                count: summary.setIndexValuesDropped, identifier: "\(identifierPrefix).drop.setNumbers",
                detail: "Burly keeps the sets in the order the file lists them."
            )
            CountRow(
                title: "Values in unrecognized columns", systemImage: "questionmark.square.dashed",
                count: summary.unknownColumnValuesDropped, identifier: "\(identifierPrefix).drop.unknownColumns"
            )
            CountRow(
                title: "Conflicting workout details", systemImage: "arrow.left.arrow.right",
                count: summary.conflictingSessionMetadataDropped, identifier: "\(identifierPrefix).drop.conflictingDetails",
                detail: "Rows that disagreed with their workout's end time or description; their sets still come in."
            )
        } header: {
            Text("Left out")
        }

        Section {
            if summary.encodingDamageDetected {
                Label {
                    Text(encodingDamageMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityIdentifier("\(identifierPrefix).encodingDamage")
            } else {
                Label("Text encoding: no damage found", systemImage: "checkmark.seal")
                    .accessibilityIdentifier("\(identifierPrefix).encodingOK")
            }

            CountRow(
                title: "Rows lost to an unclosed quote", systemImage: "quote.opening",
                count: summary.rowsLostToUnterminatedQuote, identifier: "\(identifierPrefix).drop.unclosedQuote",
                detail: summary.rowsLostToUnterminatedQuote > 0
                    ? "Approximate. A quote mark that never closes makes the rest of the file unsafe to read."
                    : nil,
                isApproximate: summary.rowsLostToUnterminatedQuote > 0
            )

            CountRow(
                title: "Rows that couldn't be read", systemImage: "exclamationmark.circle",
                count: summary.malformedRowCount, identifier: "\(identifierPrefix).drop.malformedRows"
            )
            ForEach(summary.malformedRows.prefix(Self.malformedRowDisplayLimit), id: \.rowNumber) { row in
                Text("Row \(row.rowNumber): \(HevyImportFormat.reason(row.reason))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .accessibilityIdentifier("\(identifierPrefix).malformedRow.\(row.rowNumber)")
            }
            if summary.malformedRowCount > Self.malformedRowDisplayLimit {
                Text("And \(summary.malformedRowCount - Self.malformedRowDisplayLimit) more rows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        } header: {
            Text("File problems")
        } footer: {
            Text("A problem row is skipped on its own; the rest of the file still imports.")
        }
    }

    private func rows(_ count: Int) -> String {
        count == 1 ? "1 row" : "\(count) rows"
    }

    /// The damage can sit outside any workout row (an unrecognized column
    /// name, or a record the reader already rejected for another reason),
    /// so "0 rows were set aside" is possible and reads as nonsense (m7-02
    /// review).
    private var encodingDamageMessage: String {
        let count = encodingDamagedRowCount
        guard count > 0 else {
            return "Part of this file wasn't valid text. No workout rows were set aside for it "
                + "beyond any problem rows listed below."
        }
        return "Part of this file wasn't valid text. \(rows(count)) with damaged characters "
            + "\(count == 1 ? "was" : "were") set aside rather than risk importing garbled data."
    }
}

// MARK: - Summary

private struct HevyImportSummaryView: View {
    let plan: HevyImportPlan
    let outcome: HevyImportOutcome
    let onRetry: () -> Void
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if outcome.isComplete {
                        Label("Import complete", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("Your workouts are in History and Stats.")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Import stopped part-way", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(failureMessage)
                            .foregroundStyle(.secondary)
                    }
                }
                // On the combined element, not its children: `.combine`
                // makes one accessibility element, so child identifiers
                // would not reach XCUITest (m7-02 review; same pattern as
                // SessionSummaryView.summaryRow).
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(outcome.isComplete ? "hevyImport.summary.heading" : "hevyImport.summary.failedHeading")
            }

            Section {
                CountRow(
                    title: "Workouts added", systemImage: "figure.strengthtraining.traditional",
                    count: outcome.sessionsCreated, identifier: "hevyImport.summary.workoutsAdded"
                )
                CountRow(
                    title: "Already in Burly", systemImage: "checkmark.circle",
                    count: plan.preview.alreadyImportedWorkoutCount, identifier: "hevyImport.summary.alreadyImported"
                )
                CountRow(
                    title: "Sets", systemImage: "list.number",
                    count: outcome.setsCreated, identifier: "hevyImport.summary.sets"
                )
                CountRow(
                    title: "New custom exercises", systemImage: "plus.circle",
                    count: outcome.customExercisesCreated, identifier: "hevyImport.summary.newCustoms"
                )
            } header: {
                Text("Added")
            } footer: {
                if outcome.matches(plan.preview) {
                    Text("Exactly what the preview showed.")
                        .accessibilityIdentifier("hevyImport.summary.matchesPreview")
                }
            }

            HevyImportDropReport(summary: plan.fileSummary, identifierPrefix: "hevyImport.summary")

            Section {
                if outcome.isComplete == false {
                    Button(action: onRetry) {
                        Label("Review What's Left", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("hevyImport.retryButton")
                }
                Button(action: onDone) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("hevyImport.doneButton")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var failureMessage: String {
        let total = plan.preview.newWorkoutCount
        let added = outcome.sessionsCreated == 1 ? "1 workout was" : "\(outcome.sessionsCreated) workouts were"
        // `Failure.message` is a diagnostic dump (enum cases, UUIDs), not
        // user copy (m7-02 review); name only what was being saved.
        let what = outcome.failure?.stage == .exercise ? "an exercise" : "a workout"
        return "\(added) added out of \(total) before saving \(what) failed. "
            + "Importing the same file again is safe: workouts already added are skipped, never duplicated."
    }
}

// MARK: - Problems

private struct HevyImportProblemView: View {
    let systemImage: String
    let title: String
    let message: String
    let identifier: String
    var actionTitle = "Choose Another File"
    let onChooseAnother: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("\(identifier).heading")
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(identifier).message")
                Button(action: onChooseAnother) {
                    Label(actionTitle, systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                .accessibilityIdentifier("hevyImport.chooseAnotherButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Rows

/// One number, one VoiceOver element: label "New workouts", value "3". The
/// value doubles as the UI-test contract (`XCUIElement.value`).
private struct CountRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let identifier: String
    var detail: String?
    var isApproximate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                Text(isApproximate ? "about \(count)" : "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? HierarchicalShapeStyle.secondary : .primary)
            } label: {
                Label(title, systemImage: systemImage)
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isApproximate ? "about \(count)" : "\(count)")
        .accessibilityHint(detail ?? "")
        .accessibilityIdentifier(identifier)
    }
}

private struct ValueRow: View {
    let title: String
    let systemImage: String
    let value: String
    let identifier: String

    var body: some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Formatting

enum HevyImportFormat {
    /// Dates in the same (current) zone the parse used, so the range shown
    /// is the range the time-zone footer describes.
    static func dateRange(_ range: ClosedRange<Date>) -> String {
        let lower = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
        let upper = range.upperBound.formatted(date: .abbreviated, time: .omitted)
        return lower == upper ? lower : "\(lower) – \(upper)"
    }

    static func reason(_ reason: MalformedRowReason) -> String {
        switch reason {
        case .wrongColumnCount(let expected, let actual):
            "has \(actual) columns where \(expected) were expected"
        case .missingRequiredField(let field):
            "\(field) is empty"
        case .invalidWeight(let value):
            "weight \"\(value)\" isn't a usable number"
        case .invalidReps(let value):
            "reps \"\(value)\" isn't a whole number"
        case .invalidTimestamp(let field, let value):
            "\(field) \"\(value)\" isn't a date Burly recognizes"
        case .endBeforeStart:
            "the workout ends before it starts"
        case .invalidDistance(let value):
            "distance \"\(value)\" isn't a usable number"
        case .invalidDuration(let value):
            "duration \"\(value)\" isn't a usable number"
        case .invalidUTF8:
            "contains damaged (non-UTF-8) text"
        case .blankRow:
            "is blank"
        case .unterminatedQuoteConsumedRemainder(let approxRowsLost):
            approxRowsLost == 0
                ? "opens a quote that never closes"
                : "opens a quote that never closes; about \(approxRowsLost) rows after it were skipped"
        case .strayQuoteInField:
            "has a stray quote mark inside a value"
        case .contentAfterClosingQuote:
            "has text right after a closing quote"
        case .oversizedRecord:
            "is too long to read safely"
        }
    }
}

#Preview("Intro") {
    NavigationStack {
        HevyImportView(
            viewModel: PhoneHomeViewModel(store: try! SwiftDataStore.phone(at: .inMemory)),
            onClose: {}
        )
    }
}
