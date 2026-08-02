// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 Finish: "'End workout' -> summary: duration, total volume, sets,
// any PRs -> Finish (primary) / 'Keep going' / 'Discard' (destructive,
// double-confirm)." One view serves both the pre-commit preview (nothing
// has changed yet -- Finish/Keep going/Discard are all still live options)
// and the post-commit acknowledgement (`isFinal`), so the totals shown
// never have to be recomputed or re-derived between the two -- they are
// the same `SessionSummary` value either way (`SessionSummaryBuilder`'s
// doc).
import SwiftUI
import BurlyCore

struct SessionSummaryView: View {
    let summary: SessionSummary
    let isFinal: Bool
    let isFinishing: Bool
    let onFinish: () -> Void
    let onKeepGoing: () -> Void
    let onDiscard: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: isFinal ? "checkmark.circle.fill" : "flag.checkered")
                    .font(.title)
                    .foregroundStyle(isFinal ? .green : .secondary)
                    .accessibilityHidden(true)

                Text(isFinal ? "Workout saved" : "End workout?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("sessionSummary.heading")

                VStack(spacing: 4) {
                    summaryRow(label: "Duration", value: durationText, identifier: "sessionSummary.duration")
                    summaryRow(label: "Volume", value: volumeText, identifier: "sessionSummary.volume")
                    summaryRow(label: "Sets", value: "\(summary.totalSets)", identifier: "sessionSummary.sets")
                }

                if summary.hasPersonalRecords {
                    Text("New PR: \(summary.personalRecords.count)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("sessionSummary.personalRecords")
                }

                if isFinal {
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("sessionSummary.doneButton")
                } else {
                    Button("Finish", action: onFinish)
                        .buttonStyle(.borderedProminent)
                        .disabled(isFinishing)
                        .accessibilityIdentifier("sessionSummary.finishButton")
                    Button("Keep going", action: onKeepGoing)
                        .accessibilityIdentifier("sessionSummary.keepGoingButton")
                    Button("Discard", role: .destructive, action: onDiscard)
                        .accessibilityIdentifier("sessionSummary.discardButton")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryRow(label: String, value: String, identifier: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var durationText: String {
        let total = max(0, Int(summary.duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var volumeText: String {
        String(format: "%.0f lb", summary.totalVolumeLb.rounded())
    }
}

#Preview("Preview") {
    SessionSummaryView(
        summary: SessionSummary(duration: 1830, totalVolumeKg: 1200, totalSets: 9, personalRecords: []),
        isFinal: false,
        isFinishing: false,
        onFinish: {},
        onKeepGoing: {},
        onDiscard: {},
        onDone: {}
    )
}

#Preview("Final") {
    SessionSummaryView(
        summary: SessionSummary(duration: 1830, totalVolumeKg: 1200, totalSets: 9, personalRecords: []),
        isFinal: true,
        isFinishing: false,
        onFinish: {},
        onKeepGoing: {},
        onDiscard: {},
        onDone: {}
    )
}
