// SPDX-License-Identifier: GPL-3.0-or-later
// Phone-only Swift Charts dashboard (spec §7). The view deliberately owns
// range/picker presentation state only; PhoneHomeViewModel obtains bounded
// projections and calls BurlyCore's stats layer before this file sees data.

import Charts
import BurlyCore
import SwiftUI

@MainActor
struct StatsTabView: View {
    let viewModel: PhoneHomeViewModel

    @State private var progressionRange: PhoneStatsProgressionRange = .threeMonths
    @State private var volumeRange: PhoneStatsVolumeRange = .eightWeeks
    @State private var selectedExerciseID: UUID?

    var body: some View {
        content
            .navigationTitle("Stats")
            .task { reloadStats() }
            .onChange(of: progressionRange) { _, _ in reloadStats() }
            .onChange(of: volumeRange) { _, _ in reloadStats() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.statsState {
        case .loading:
            ProgressView()
                .accessibilityIdentifier("statsTab.loading")
        case .failed(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load stats",
                message: message,
                identifierPrefix: "statsTab",
                onRetry: { reloadStats() }
            )
        case .loaded:
            if let stats = viewModel.stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        progressionCard(stats)
                        volumeCard(stats)
                        muscleSplitCard(stats)
                        consistencyCard(stats)
                    }
                    .padding()
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                StatsChartEmptyState(
                    title: "No stats yet",
                    message: "Complete a workout and your stats will start appearing here.",
                    identifier: "statsTab.emptyState.heading"
                )
            }
        }
    }

    private func progressionCard(_ stats: PhoneStatsDashboard) -> some View {
        StatsCard(title: "Exercise progression", subtitle: "Top set and estimated 1RM") {
            if let exercise = stats.progression.exercise {
                Picker(
                    "Exercise",
                    selection: Binding(
                        get: { selectedExerciseID ?? exercise.id },
                        set: { newID in
                            selectedExerciseID = newID
                            reloadStats()
                        }
                    )
                ) {
                    ForEach(stats.exercises) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("statsTab.progression.exercisePicker")

                rangePicker(
                    selection: $progressionRange,
                    identifier: "statsTab.progression.rangePicker",
                    ranges: PhoneStatsProgressionRange.allCases
                )

                if stats.progression.points.isEmpty {
                    StatsChartEmptyState(
                        title: "No working sets in this range",
                        message: "Log a non-warmup set for \(exercise.name) to see its progression.",
                        identifier: "statsTab.progression.empty"
                    )
                } else {
                    Chart {
                        ForEach(stats.progression.points, id: \.sessionID) { point in
                            LineMark(
                                x: .value("Session", point.date),
                                y: .value("Weight (kg)", point.topWeight.kg)
                            )
                            .foregroundStyle(.blue)
                            .symbol(.circle)

                            LineMark(
                                x: .value("Session", point.date),
                                y: .value("Estimated 1RM (kg)", point.estimatedOneRepMax)
                            )
                            .foregroundStyle(.orange)
                            .symbol(.diamond)
                        }

                        ForEach(Array(stats.progression.records.enumerated()), id: \.offset) { _, record in
                            PointMark(
                                x: .value("PR date", record.date),
                                y: .value("PR", record.value)
                            )
                            .symbol(record.kind == .topWeight ? .triangle : .square)
                            .foregroundStyle(.red)
                        }
                    }
                    .chartYAxisLabel("kg")
                    .chartLegend(position: .bottom, alignment: .leading) {
                        HStack(spacing: 16) {
                            Label("Top set", systemImage: "circle.fill").foregroundStyle(.blue)
                            Label("Estimated 1RM", systemImage: "diamond.fill").foregroundStyle(.orange)
                            Label("Personal record", systemImage: "triangle.fill").foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                    .frame(height: 220)
                    .accessibilityIdentifier("statsTab.progression.chart")
                    .accessibilityLabel("Exercise progression chart for \(exercise.name)")
                }
            } else {
                StatsChartEmptyState(
                    title: "No exercises yet",
                    message: "Add and log an exercise to see progression and personal records.",
                    identifier: "statsTab.progression.empty"
                )
            }
        }
    }

    private func volumeCard(_ stats: PhoneStatsDashboard) -> some View {
        StatsCard(title: "Weekly volume", subtitle: "Working sets only") {
            rangePicker(
                selection: $volumeRange,
                identifier: "statsTab.volume.rangePicker",
                ranges: PhoneStatsVolumeRange.allCases
            )

            if stats.volume.contains(where: { $0.totalVolumeKg > 0 }) {
                Chart(stats.volume) { week in
                    BarMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Volume", week.totalVolumeKg)
                    )
                    .foregroundStyle(.mint.gradient)
                }
                .chartYAxisLabel("kg-reps")
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: max(1, volumeRange.weekCount / 4)))
                }
                .frame(height: 200)
                .accessibilityIdentifier("statsTab.volume.chart")
                .accessibilityLabel("Weekly training volume chart")
            } else {
                StatsChartEmptyState(
                    title: "No volume in this range",
                    message: "Volume is weight times reps for working sets; warmups are excluded.",
                    identifier: "statsTab.volume.empty"
                )
            }

            Text("Weeks follow your calendar’s time zone and first-day-of-week setting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statsTab.volume.calendarNote")
        }
    }

    private func muscleSplitCard(_ stats: PhoneStatsDashboard) -> some View {
        let slices = muscleSlices(from: stats.muscleSplit)
        return StatsCard(title: "Muscle split", subtitle: "Last 4 weeks") {
            if slices.isEmpty {
                StatsChartEmptyState(
                    title: "No working sets in the last 4 weeks",
                    message: "Log working sets to see how their muscle tags are shared.",
                    identifier: "statsTab.muscleSplit.empty"
                )
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Share", slice.fraction),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(by: .value("Muscle group", slice.name))
                }
                .frame(height: 210)
                .accessibilityIdentifier("statsTab.muscleSplit.chart")
                .accessibilityLabel("Muscle split chart")

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slices) { slice in
                        Text("\(slice.name): \(slice.fraction, format: .percent.precision(.fractionLength(0)))")
                    }
                }
                .font(.footnote)
                .accessibilityIdentifier("statsTab.muscleSplit.legend")

                Text(
                    "Total: 100% of working sets. Each set is shared equally across its exercise tags. Unattributed work is included (\(stats.muscleSplit.unattributedFraction, format: .percent.precision(.fractionLength(0)))) rather than redistributed."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statsTab.muscleSplit.attributionNote")
            }
        }
    }

    private func consistencyCard(_ stats: PhoneStatsDashboard) -> some View {
        return StatsCard(title: "Consistency", subtitle: "Sessions this week vs. a typical week") {
            if stats.consistency.weeks.isEmpty {
                StatsChartEmptyState(
                    title: "No sessions in the last 8 weeks",
                    message: "Log a workout to start a simple weekly consistency view.",
                    identifier: "statsTab.consistency.empty"
                )
            } else {
                Text(
                    "This week: \(stats.consistency.currentWeekCount) · Typical week: \(stats.consistency.trailingTypicalWeekCount, format: .number.precision(.fractionLength(1)))"
                )
                .font(.subheadline)
                .accessibilityIdentifier("statsTab.consistency.summary")

                Chart(stats.consistencyWeeks) { week in
                    BarMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Sessions", week.count)
                    )
                    .foregroundStyle(.indigo.gradient)

                    RuleMark(y: .value("Typical week", stats.consistency.trailingTypicalWeekCount))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(dash: [4, 4]))
                }
                .chartYAxisLabel("sessions")
                .frame(height: 190)
                .accessibilityIdentifier("statsTab.consistency.chart")
                .accessibilityLabel("Weekly consistency chart")

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(stats.calendarDots) { day in
                        Circle()
                            .fill(day.hasSession ? Color.indigo : Color.secondary.opacity(0.18))
                            .frame(width: 12, height: 12)
                            .accessibilityLabel(day.hasSession ? "Workout logged" : "No workout")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Calendar dots for the last 28 days")
                .accessibilityIdentifier("statsTab.consistency.calendarDots")

                Text("Dots show days with a logged session. This view intentionally does not count streaks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("statsTab.consistency.calendarNote")
            }
        }
    }

    private func rangePicker<Range: CaseIterable & Identifiable & Hashable>(
        selection: Binding<Range>,
        identifier: String,
        ranges: Range.AllCases
    ) -> some View where Range.AllCases: RandomAccessCollection, Range: PhoneStatsRangeTitle {
        Picker("Range", selection: selection) {
            ForEach(Array(ranges), id: \.self) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }

    private func muscleSlices(from summary: MuscleSplitSummary) -> [PhoneStatsMuscleSlice] {
        var slices = summary.shares.map {
            PhoneStatsMuscleSlice(name: muscleGroupTitle($0.muscleGroup), fraction: $0.fraction)
        }
        if summary.unattributedFraction > 0 {
            slices.append(PhoneStatsMuscleSlice(name: "Unattributed", fraction: summary.unattributedFraction))
        }
        return slices
    }

    private func reloadStats() {
        viewModel.loadStats(
            progressionRange: progressionRange,
            volumeRange: volumeRange,
            exerciseID: selectedExerciseID
        )
    }
}

private protocol PhoneStatsRangeTitle {
    var title: String { get }
}

extension PhoneStatsProgressionRange: PhoneStatsRangeTitle {}
extension PhoneStatsVolumeRange: PhoneStatsRangeTitle {}

private struct PhoneStatsMuscleSlice: Identifiable {
    let name: String
    let fraction: Double

    var id: String { name }
}

private struct StatsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatsChartEmptyState: View {
    let title: String
    let message: String
    let identifier: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .accessibilityIdentifier(identifier)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier).message")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private func muscleGroupTitle(_ group: MuscleGroup) -> String {
    switch group {
    case .chest: "Chest"
    case .upperBack: "Upper back"
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

#Preview {
    StatsTabView(viewModel: .previewLoaded)
}
