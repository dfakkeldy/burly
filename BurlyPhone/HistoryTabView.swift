// SPDX-License-Identifier: GPL-3.0-or-later
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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
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
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No history yet",
                    message: "Workouts you finish will show up here, starting with your first session.",
                    identifierPrefix: "historyTab"
                )
            } else if viewModel.sessionRows.isEmpty {
                // Count says history exists but the rows (this tab's lazy
                // load) haven't landed yet.
                ProgressView()
            } else {
                List {
                    if let placeholder = viewModel.namingQueue.first {
                        NavigationLink {
                            NamingQueueView(viewModel: viewModel, placeholder: placeholder)
                        } label: {
                            Label("Name your custom exercise", systemImage: "tag")
                        }
                        .accessibilityIdentifier("historyTab.namingQueueBanner")
                    }
                    ForEach(weekGroups) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    HistorySessionDetailView(viewModel: viewModel, session: session)
                                } label: {
                                    HistorySessionRow(session: session, hasPersonalRecord: prSessionIDs.contains(session.id))
                                }
                                .accessibilityIdentifier("historyTab.sessionRow.\(session.id.uuidString)")
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

    /// A row earns the lightweight history badge only when one of its working
    /// sets exceeds every earlier logged set for the same exercise. The Stats
    /// projection remains the detailed PR authority; this keeps the list
    /// honest without adding a second persistence surface.
    private var prSessionIDs: Set<UUID> {
        var bestWeightByExercise: [UUID: Double] = [:]
        var records = Set<UUID>()
        for session in viewModel.sessionRows.sorted(by: { $0.startedAt < $1.startedAt }) {
            var isRecord = false
            for item in session.items {
                guard let exerciseID = item.exerciseID else { continue }
                for set in item.sets where !set.isWarmup {
                    if set.weightKg > bestWeightByExercise[exerciseID, default: -.infinity] {
                        isRecord = true
                        bestWeightByExercise[exerciseID] = set.weightKg
                    }
                }
            }
            if isRecord { records.insert(session.id) }
        }
        return records
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
        return "\(Int(volume.rounded())) kg"
    }
}

#Preview {
    HistoryTabView(viewModel: .previewLoaded)
}
