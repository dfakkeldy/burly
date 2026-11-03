// SPDX-License-Identifier: GPL-3.0-or-later
// Phone-only Swift Charts dashboard (spec §7). The view deliberately owns
// range/picker presentation state only; PhoneHomeViewModel obtains bounded
// projections and calls BurlyCore's stats layer before this file sees data.
//
// Every weight here is computed in canonical kg and converted to the
// Settings display unit only at the mark/label level (spec §7 "canonical kg
// → display unit"; §9 acceptance #2), so a unit switch re-renders without
// re-querying the store.
//
// At accessibility text sizes the charts keep their data and ranges but
// change how they label it (#30, #37, #38): date axes show only their first
// and last dates, value axes ask for fewer ticks, units move to their own
// line above the plot, and chart height grows by the room the labels need.
// At the default size the charts look as they did before.

import Charts
import BurlyCore
import SwiftUI

@MainActor
struct StatsTabView: View {
    let viewModel: PhoneHomeViewModel

    @State private var progressionRange: PhoneStatsProgressionRange = .threeMonths
    @State private var volumeRange: PhoneStatsVolumeRange = .eightWeeks
    @State private var selectedExerciseID: UUID?
    @AppStorage(DisplayUnitPreference.storageKey) private var unit = DisplayUnitPreference.defaultUnit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Room for axis labels on top of each chart's plot height. It is 60 pt
    /// at the default size, so the plot heights below add up to the charts'
    /// original 220/200/190 pt, and it grows with text: only the labels get
    /// bigger, so only their share of the frame scales.
    @ScaledMetric(relativeTo: .caption) private var axisLabelAllowance: CGFloat = 60

    var body: some View {
        NavigationStack {
            content.navigationTitle("Stats")
        }
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
            // `loadStats` sets `stats` before it reports `.loaded`, so there
            // is no loaded-but-empty dashboard; each card owns its own
            // empty state instead.
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
            }
        }
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private func progressionCard(_ stats: PhoneStatsDashboard) -> some View {
        let axisDates = endpointDates(stats.progression.points.map(\.date))
        return StatsCard(title: "Exercise progression", subtitle: "Top set and estimated 1RM") {
            if let exercise = stats.progression.exercise {
                exerciseMenu(stats, selected: exercise)

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
                    chartUnitLine(unit.symbol)

                    Chart {
                        ForEach(stats.progression.points, id: \.sessionID) { point in
                            LineMark(
                                x: .value("Session", point.date),
                                y: .value(seriesLabel("Top set"), unit.displayValue(of: point.topWeight)),
                                series: .value("Series", "Top set")
                            )
                            .foregroundStyle(by: .value("Series", "Top set"))
                            .symbol(.circle)

                            LineMark(
                                x: .value("Session", point.date),
                                y: .value(seriesLabel("Estimated 1RM"), unit.displayValue(fromKilograms: point.estimatedOneRepMax)),
                                series: .value("Series", "Estimated 1RM")
                            )
                            .foregroundStyle(by: .value("Series", "Estimated 1RM"))
                            .symbol(.diamond)
                        }

                        ForEach(Array(stats.progression.records.enumerated()), id: \.offset) { _, record in
                            PointMark(
                                x: .value("PR date", record.date),
                                y: .value(seriesLabel("Personal record"), unit.displayValue(fromKilograms: record.value))
                            )
                            .symbol(record.kind == .topWeight ? .triangle : .square)
                            .foregroundStyle(by: .value("Series", "Personal record"))
                        }
                    }
                    .chartForegroundStyleScale([
                        "Top set": Color.blue,
                        "Estimated 1RM": Color.orange,
                        "Personal record": Color.red
                    ])
                    .statsYAxisLabel(unit.symbol, isAccessibilitySize: isAccessibilitySize)
                    .chartXAxis {
                        if isAccessibilitySize {
                            endpointDateMarks(axisDates)
                        } else {
                            AxisMarks()
                        }
                    }
                    .chartYAxis {
                        if isAccessibilitySize {
                            AxisMarks(values: .automatic(desiredCount: 3))
                        } else {
                            AxisMarks()
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: 160 + axisLabelAllowance)
                    .accessibilityIdentifier("statsTab.progression.chart")
                    .accessibilityLabel("Exercise progression chart for \(exercise.name)")

                    progressionLegend(stats.progression.records)

                    // A findable, VoiceOver-readable statement of the
                    // chart's headline numbers in the display unit. Worded
                    // as "best in this range" rather than "PR": the points
                    // are range-filtered, while PRs are judged against the
                    // exercise's whole history (PhoneHomeViewModel).
                    Text(progressionSummary(stats.progression.points))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("statsTab.progression.summary")
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

    /// A menu rather than a `.menu` picker, so a long exercise name wraps
    /// instead of clipping at large text (#30). Exercises trained in the
    /// last 52 weeks come first; the view model has already left out
    /// archived exercises that weren't.
    private func exerciseMenu(_ stats: PhoneStatsDashboard, selected exercise: ExerciseData) -> some View {
        let recent = stats.exercises.filter { stats.recentExerciseIDs.contains($0.id) }
        let others = stats.exercises.filter { !stats.recentExerciseIDs.contains($0.id) }
        return Menu {
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
                if recent.isEmpty || others.isEmpty {
                    exerciseOptions(stats.exercises)
                } else {
                    Section("Trained in the last year") { exerciseOptions(recent) }
                    Section("Other exercises") { exerciseOptions(others) }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(exercise.name)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("Exercise")
        .accessibilityValue(exercise.name)
        .accessibilityIdentifier("statsTab.progression.exercisePicker")
    }

    private func exerciseOptions(_ exercises: [ExerciseData]) -> some View {
        ForEach(exercises) { candidate in
            Text(candidate.name).tag(candidate.id)
        }
    }

    /// Keep legend text in the ordinary accessibility tree, outside the
    /// chart's synthesized data representation. Narrow/large-text layouts
    /// can use a vertical legend without squeezing the plot itself.
    private func progressionLegend(_ records: [PersonalRecord]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { progressionLegendItems(records) }
            VStack(alignment: .leading, spacing: 6) { progressionLegendItems(records) }
        }
        .font(.caption)
    }

    /// The two PR kinds draw different symbols, so each gets its own entry,
    /// shown only when the range has a PR of that kind.
    @ViewBuilder
    private func progressionLegendItems(_ records: [PersonalRecord]) -> some View {
        legendLabel("Top set", symbol: "circle.fill", color: .blue, id: "topSet")
        legendLabel("Estimated 1RM", symbol: "diamond.fill", color: .orange, id: "estimate")
        if records.contains(where: { $0.kind == .topWeight }) {
            legendLabel("Weight PR", symbol: "triangle.fill", color: .red, id: "recordWeight")
        }
        if records.contains(where: { $0.kind == .estimatedOneRepMax }) {
            legendLabel("Est. 1RM PR", symbol: "square.fill", color: .red, id: "recordEstimate")
        }
    }

    private func legendLabel(_ title: String, symbol: String, color: Color, id: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .accessibilityIdentifier("statsTab.progression.legend.\(id)")
    }

    private func volumeCard(_ stats: PhoneStatsDashboard) -> some View {
        let axisDates = endpointDates(stats.volume.map(\.weekStart))
        return StatsCard(title: "Weekly volume", subtitle: "Working sets only") {
            rangePicker(
                selection: $volumeRange,
                identifier: "statsTab.volume.rangePicker",
                ranges: PhoneStatsVolumeRange.allCases
            )

            if stats.volume.contains(where: { $0.totalVolumeKg > 0 }) {
                chartUnitLine(volumeUnitLabel)

                Chart(stats.volume) { week in
                    BarMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value("Volume (\(volumeUnitLabel))" as String, unit.displayValue(fromKilograms: week.totalVolumeKg))
                    )
                    .foregroundStyle(.mint.gradient)
                }
                .statsYAxisLabel(volumeUnitLabel, isAccessibilitySize: isAccessibilitySize)
                .chartXAxis {
                    if isAccessibilitySize {
                        endpointDateMarks(axisDates)
                    } else {
                        AxisMarks(values: .stride(by: .weekOfYear, count: max(1, volumeRange.weekCount / 4)))
                    }
                }
                .chartYAxis {
                    if isAccessibilitySize {
                        // "3K" rather than "3,000": four digits at the
                        // largest size take a third of the plot's width.
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                        }
                    } else {
                        AxisMarks()
                    }
                }
                .frame(height: 140 + axisLabelAllowance)
                .accessibilityIdentifier("statsTab.volume.chart")
                .accessibilityLabel("Weekly training volume chart")
            } else {
                StatsChartEmptyState(
                    title: "No volume in this range",
                    message: "Volume is weight times reps for working sets. Warmups and bodyweight sets add nothing to it.",
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
                // The chart's own legend is hidden: the rows below are the
                // one legend, and they share the sectors' colour scale
                // (#38). The donut carries no text, so it needs no room to
                // grow with Dynamic Type.
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Share", slice.fraction),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(by: .value("Muscle group", slice.name))
                }
                .chartForegroundStyleScale(domain: slices.map(\.name), range: slices.map(\.color))
                .chartLegend(.hidden)
                .frame(height: 210)
                .accessibilityIdentifier("statsTab.muscleSplit.chart")
                .accessibilityLabel("Muscle split chart")

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices) { slice in
                        MuscleSplitLegendRow(slice: slice)
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("statsTab.muscleSplit.legend")

                Text(attributionNote(stats.muscleSplit))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("statsTab.muscleSplit.attributionNote")
            }
        }
    }

    private func attributionNote(_ summary: MuscleSplitSummary) -> String {
        let shared = "Total: 100% of working sets. Each set is shared equally across its exercise tags."
        guard summary.unattributedFraction > 0 else { return shared }
        return "\(shared) Unattributed work is included (\(percentText(summary.unattributedFraction))) rather than redistributed."
    }

    private func consistencyCard(_ stats: PhoneStatsDashboard) -> some View {
        let axisDates = endpointDates(stats.consistencyWeeks.map(\.weekStart))
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

                chartUnitLine("sessions")

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
                .statsYAxisLabel("sessions", isAccessibilitySize: isAccessibilitySize)
                .chartXAxis {
                    if isAccessibilitySize {
                        endpointDateMarks(axisDates)
                    } else {
                        AxisMarks()
                    }
                }
                .chartYAxis {
                    if isAccessibilitySize {
                        // Whole sessions only, and just the floor and the
                        // busiest week, so the large labels never overlap.
                        AxisMarks(values: [0, max(1, stats.consistencyWeeks.map(\.count).max() ?? 0)])
                    } else {
                        AxisMarks()
                    }
                }
                .frame(height: 130 + axisLabelAllowance)
                .accessibilityIdentifier("statsTab.consistency.chart")
                .accessibilityLabel("Weekly consistency chart")

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(stats.calendarDots) { day in
                        Circle()
                            .fill(day.hasSession ? Color.indigo : Color.secondary.opacity(0.18))
                            .frame(width: 12, height: 12)
                            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                            .accessibilityValue(day.hasSession ? "Workout logged" : "No workout")
                            .accessibilityIdentifier("statsTab.consistency.day.\(day.date.timeIntervalSince1970)")
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

    /// At accessibility sizes Charts' own value-axis title collides with the
    /// top tick label (#37), so the unit gets its own line above the plot,
    /// over the value labels. At other sizes `statsYAxisLabel` keeps the
    /// Charts title and this draws nothing.
    @ViewBuilder
    private func chartUnitLine(_ label: String) -> some View {
        if isAccessibilitySize {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    /// The first and last of `dates` (one date if they are the same), for
    /// the large-text date axes.
    private func endpointDates(_ dates: [Date]) -> [Date] {
        guard let first = dates.first, let last = dates.last else { return [] }
        return first == last ? [first] : [first, last]
    }

    /// The large-text date axis: only the first and last dates, each
    /// stacked month over day so it fits under the plot, anchored inward
    /// so neither runs off the chart's edge. The year is added unless
    /// both dates are in the current year.
    private func endpointDateMarks(_ dates: [Date]) -> some AxisContent {
        let calendar = Calendar.autoupdatingCurrent
        let showsYear = dates.contains { !calendar.isDate($0, equalTo: .now, toGranularity: .year) }
        return AxisMarks(values: dates) { value in
            AxisGridLine()
            AxisTick()
            if let date = value.as(Date.self) {
                let isFirst = dates.count > 1 && date == dates.first
                let isLast = dates.count > 1 && date == dates.last
                AxisValueLabel(anchor: isFirst ? .topLeading : (isLast ? .topTrailing : .top)) {
                    VStack(alignment: isFirst ? .leading : (isLast ? .trailing : .center), spacing: 0) {
                        Text(date, format: .dateTime.month(.abbreviated))
                        Text(date, format: .dateTime.day())
                        if showsYear {
                            Text(date, format: .dateTime.year())
                        }
                    }
                    .font(.caption2)
                }
            }
        }
    }

    private func muscleSlices(from summary: MuscleSplitSummary) -> [PhoneStatsMuscleSlice] {
        var slices = summary.shares.map {
            PhoneStatsMuscleSlice(
                key: $0.muscleGroup.rawValue,
                name: muscleGroupTitle($0.muscleGroup),
                fraction: $0.fraction,
                color: muscleGroupColor($0.muscleGroup)
            )
        }
        if summary.unattributedFraction > 0 {
            slices.append(PhoneStatsMuscleSlice(
                key: "unattributed",
                name: "Unattributed",
                fraction: summary.unattributedFraction,
                color: .gray
            ))
        }
        return slices
    }

    /// Volume is Σ weight × reps, so its axis keeps the existing "kg-reps"
    /// shape in whichever unit is shown.
    private var volumeUnitLabel: String { "\(unit.symbol)-reps" }

    /// Mark labels that carry the unit must reach Charts as `String`, never as
    /// an interpolated string literal. A literal with interpolation becomes a
    /// `LocalizedStringKey` with format arguments, and two identically built
    /// keys compare unequal; Charts keys its internal dictionaries on these
    /// labels, so the populated Stats tab crashed intermittently with
    /// KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS (local acceptance,
    /// 2026-10-29). `String` equality and hashing always agree.
    private func seriesLabel(_ name: String) -> String { "\(name) (\(unit.symbol))" }

    /// "Best in this range: top set 198.4 lb · estimated 1RM 251.3 lb".
    /// Only called with a non-empty point list.
    private func progressionSummary(_ points: [ExerciseSessionPoint]) -> String {
        let bestTopSet = points.map(\.topWeight.kg).max() ?? 0
        let bestEstimate = points.map(\.estimatedOneRepMax).max() ?? 0
        return "Best in this range: top set \(unit.formatted(kilograms: bestTopSet)) · estimated 1RM \(unit.formatted(kilograms: bestEstimate))"
    }

    private func reloadStats() {
        viewModel.loadStats(
            progressionRange: progressionRange,
            volumeRange: volumeRange,
            exerciseID: selectedExerciseID
        )
    }
}

private extension View {
    /// Charts' value-axis title, except at accessibility sizes, where
    /// `StatsTabView.chartUnitLine` shows the unit above the chart instead.
    @ViewBuilder
    func statsYAxisLabel(_ label: String, isAccessibilitySize: Bool) -> some View {
        if isAccessibilitySize {
            self
        } else {
            chartYAxisLabel(label)
        }
    }
}

private protocol PhoneStatsRangeTitle {
    var title: String { get }
}

extension PhoneStatsProgressionRange: PhoneStatsRangeTitle {}
extension PhoneStatsVolumeRange: PhoneStatsRangeTitle {}

private struct PhoneStatsMuscleSlice: Identifiable {
    /// Stable across loads: a `MuscleGroup` raw value, or "unattributed".
    let key: String
    let name: String
    let fraction: Double
    let color: Color

    var id: String { key }
}

/// One muscle-split legend row: swatch, group name and percentage, read by
/// VoiceOver as one element. The percentage sits on the name's line when
/// it fits and drops under the name when it doesn't, so a long name at a
/// large size wraps without pushing the number off the card.
private struct MuscleSplitLegendRow: View {
    let slice: PhoneStatsMuscleSlice

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                swatch
                Text(slice.name)
                Spacer(minLength: 8)
                Text(percent).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    swatch
                    Text(slice.name).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    swatch.hidden()
                    Text(percent).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slice.name)
        .accessibilityValue(percent)
        .accessibilityIdentifier("statsTab.muscleSplit.legend.\(slice.key)")
    }

    private var percent: String { percentText(slice.fraction) }

    private var swatch: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(slice.color)
            .imageScale(.small)
    }
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

/// Whole percent, as the split's legend and attribution note both show it.
private func percentText(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
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

/// One fixed colour per group, so a group keeps its colour from load to
/// load and no two groups share one (Charts' automatic palette repeats
/// after eight). Unattributed work is grey.
private func muscleGroupColor(_ group: MuscleGroup) -> Color {
    switch group {
    case .chest: .blue
    case .upperBack: .green
    case .lats: .teal
    case .shoulders: .orange
    case .biceps: .purple
    case .triceps: .pink
    case .forearms: .brown
    case .quads: .red
    case .hamstrings: .indigo
    case .glutes: .yellow
    case .calves: .mint
    case .core: .cyan
    }
}

// `previewLoaded` exists only in Debug, and `#Preview` compiles in Release too.
#if DEBUG
#Preview {
    StatsTabView(viewModel: .previewLoaded)
}
#endif
