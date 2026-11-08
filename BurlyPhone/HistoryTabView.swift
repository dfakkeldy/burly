// SPDX-License-Identifier: MIT
// History tab (spec m5-01, the default tab): a real, store-backed empty
// state on zero history, and a minimal list of logged sessions once any
// exist -- the full history UI is a later task, but "no history" must be
// the store's answer, not a hardcoded screen.
//
// Rows load only when this tab is shown (m5-01 review finding 3): the
// shell's appearance load answers existence with the bounded
// `loggedSessionCount()`; the actual session rows come from the store's §6
// surface in this tab's `.task`, so a long-time user's history graph is
// never hydrated just to draw the shell. Failures render in this tab's own
// domain state (finding 4) with a visible Retry.

import BurlyCore
import SwiftUI

@MainActor
struct HistoryTabView: View {
    let viewModel: PhoneHomeViewModel
    /// The row a swipe asked to delete, until the confirmation answers.
    @State private var deleteCandidate: SessionData?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .confirmationDialog(
                    "Delete this workout?",
                    isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                    titleVisibility: .visible,
                    presenting: deleteCandidate
                ) { session in
                    Button("Delete Workout", role: .destructive) {
                        // A failure is reported as a row at the top of the
                        // list, not an alert: this runs while the dialog is
                        // closing, when an alert can be dropped.
                        do {
                            try viewModel.deleteHistorySession(session)
                        } catch {
                            viewModel.noteHistoryDeleteFailure(session, error: error)
                        }
                        deleteCandidate = nil
                    }
                    .accessibilityIdentifier("historyTab.confirmDeleteSession")
                } message: { session in
                    Text(HistorySessionDeletion.confirmationMessage(for: session))
                }
        }
            // Rows only when the tab is shown (finding 3).
            .task { viewModel.loadSessionsForDisplay() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.sessionsState {
        case .loading:
            ProgressView()
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load history",
                message: message,
                identifierPrefix: "historyTab",
                onRetry: { viewModel.loadSessionsForDisplay() }
            )
        case .loaded:
            if viewModel.loggedSessionCount == 0 {
                VStack(spacing: 0) {
                    // Deleting the last workout lands here, and its Health
                    // report must still be seen.
                    ForEach(viewModel.historyNotices) { notice in
                        HistoryNoticeRow(notice: notice) { viewModel.dismissHistoryNotice(id: notice.id) }
                            .padding()
                    }
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "No history yet",
                        message: "Workouts you finish will show up here, starting with your first session.",
                        identifierPrefix: "historyTab"
                    )
                }
            } else if viewModel.sessionRows.isEmpty {
                // Count says history exists but the rows (this tab's lazy
                // load) haven't landed yet.
                ProgressView()
            } else {
                // Share this whole-history projection across every lazy row.
                let recordSessionIDs = prSessionIDs
                List {
                    // A delete's Health half reports here when it finishes,
                    // whether it started from a row or from the detail
                    // screen (closed by then). A row, not an alert: an alert
                    // raised the moment a dialog closes or a pop animates is
                    // a presentation that can be dropped, and this one tells
                    // the user about a copy they still have to remove.
                    if !viewModel.historyNotices.isEmpty {
                        Section {
                            ForEach(viewModel.historyNotices) { notice in
                                HistoryNoticeRow(notice: notice) { viewModel.dismissHistoryNotice(id: notice.id) }
                            }
                        }
                    }
                    if let placeholder = viewModel.namingQueue.first {
                        NavigationLink {
                            NamingQueueView(viewModel: viewModel, placeholder: placeholder)
                        } label: {
                            Label("Name your custom exercise", systemImage: "tag")
                        }
                        // Keyed by placeholder: with two in the queue, the
                        // second must get its own fresh naming state, not
                        // the first one's typed name and tags.
                        .id(placeholder.id)
                        .accessibilityIdentifier("historyTab.namingQueueBanner")
                    }
                    ForEach(weekGroups) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    HistorySessionDetailView(viewModel: viewModel, session: session)
                                } label: {
                                    HistorySessionRow(session: session, hasPersonalRecord: recordSessionIDs.contains(session.id))
                                }
                                .accessibilityIdentifier("historyTab.sessionRow.\(session.id.uuidString)")
                                // Not `role: .destructive`: that role makes
                                // the List animate the row away at once,
                                // before the confirmation has been answered.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        deleteCandidate = session
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                    .accessibilityIdentifier("historyTab.deleteSession.\(session.id.uuidString)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var weekGroups: [HistoryWeekGroup] {
        HistoryWeekGroup.groups(from: viewModel.sessionRows)
    }

    /// History and Stats use the same two record kinds and tie rules.
    private var prSessionIDs: Set<UUID> {
        let slices = viewModel.sessionRows.flatMap { session in
            session.items.flatMap { item in
                item.sets.map { set in
                    SetRecordSlice(
                        sessionID: session.id,
                        sessionStartedAt: session.startedAt,
                        exerciseID: item.exerciseID,
                        set: set
                    )
                }
            }
        }
        return ExerciseProgressionStats.personalRecordSessionIDs(from: slices)
    }
}

/// The Health report after a history delete (HistoryWorkoutHealthCleanup.swift).
private struct HistoryNoticeRow: View {
    let notice: HistoryNotice
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(notice.title, systemImage: notice.systemImage)
                .font(.headline)
                .accessibilityIdentifier("historyTab.notice.title.\(notice.id.uuidString)")
            Text(notice.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("historyTab.notice.message.\(notice.id.uuidString)")
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("historyTab.notice.dismiss.\(notice.id.uuidString)")
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryWeekGroup: Identifiable {
    let start: Date
    let sessions: [SessionData]
    var id: Date { start }
    var title: String { start.formatted(.dateTime.month(.wide).day().year()) }

    static func groups(from sessions: [SessionData], calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        Dictionary(grouping: sessions) { calendar.dateInterval(of: .weekOfYear, for: $0.startedAt)?.start ?? $0.startedAt }
            .map { Self(start: $0.key, sessions: $0.value) }
            .sorted { $0.start > $1.start }
    }
}

private struct HistorySessionRow: View {
    let session: SessionData
    let hasPersonalRecord: Bool
    /// Spec §9 #2: the volume total renders in the Settings display unit.
    @AppStorage(DisplayUnitPreference.storageKey) private var unit = DisplayUnitPreference.defaultUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.routineName ?? "Workout").font(.headline)
                if session.revision > 1 {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edited")
                        .accessibilityIdentifier("historyTab.editedGlyph.\(session.id.uuidString)")
                }
                Spacer()
                if hasPersonalRecord {
                    Text("PR").font(.caption.weight(.bold)).foregroundStyle(.tint)
                        .accessibilityIdentifier("historyTab.prBadge.\(session.id.uuidString)")
                }
            }
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text("\(durationText) · \(volumeText)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        let seconds = (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    private var volumeText: String {
        let workingSets = session.items.flatMap { $0.sets }.filter { !$0.isWarmup }
        let volume = workingSets.reduce(0.0) { partial, set in
            partial + set.weightKg * Double(set.reps)
        }
        return unit.formattedVolume(kilograms: volume)
    }
}

// `previewLoaded` exists only in Debug, and `#Preview` compiles in Release too.
#if DEBUG
#Preview {
    HistoryTabView(viewModel: .previewLoaded)
}
#endif
