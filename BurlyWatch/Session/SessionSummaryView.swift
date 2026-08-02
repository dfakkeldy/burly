// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 Finish: "'End workout' -> summary: duration, total volume, sets,
// any PRs -> Finish (primary) / 'Keep going' / 'Discard' (destructive,
// double-confirm)." One view serves both the pre-commit preview (nothing
// has changed yet -- Finish/Keep going/Discard are all still live options)
// and the post-commit acknowledgement (`isFinal`), so the totals shown
// never have to be recomputed or re-derived between the two -- they are
// the same `SessionSummary` value either way (`SessionSummaryBuilder`'s
// doc).
//
// `saveError` / `onRetryFinish` surface a Finish whose `engine.finish()`
// succeeded but whose follow-up save didn't (m2-03 review finding 6):
// once that happens, `isFinishing` stays true and Keep going / Discard are
// disabled -- the in-memory session is already `.logged`, so "Keep going"
// would hand the lifter a logging screen whose engine rejects every
// further mutation. Retry is the only forward path besides the save
// eventually succeeding.
//
// A failed Discard (m2-03 review finding 9) does **not** get its own error
// slot here -- Discard is reachable both from this screen's own button and
// directly from the ellipsis menu (no summary preview involved), so its
// failure routes through `SessionViewModel.saveFailure`/`SaveFailureView`
// instead, which is visible regardless of which screen Discard was
// launched from.
import SwiftUI
import BurlyCore

struct SessionSummaryView: View {
    let summary: SessionSummary
    let isFinal: Bool
    let isFinishing: Bool
    let saveError: String?
    let onFinish: () -> Void
    let onRetryFinish: () -> Void
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
                    // m2-03 review finding 10: this is a digest-scoped
                    // comparison against last time's numbers, never a real
                    // all-time PR (`SessionSummary`'s own doc explains why
                    // the watch cannot compute one) -- the copy must never
                    // claim "PR."
                    Text("Heavier than last time: \(summary.personalRecords.count)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("sessionSummary.beatLastTime")
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

                    if let saveError {
                        Text(saveError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("sessionSummary.saveError")
                        Button("Retry", action: onRetryFinish)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("sessionSummary.retryFinishButton")
                    }

                    Button("Keep going", action: onKeepGoing)
                        .disabled(isFinishing)
                        .accessibilityIdentifier("sessionSummary.keepGoingButton")
                    Button("Discard", role: .destructive, action: onDiscard)
                        .disabled(isFinishing)
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
        saveError: nil,
        onFinish: {},
        onRetryFinish: {},
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
        saveError: nil,
        onFinish: {},
        onRetryFinish: {},
        onKeepGoing: {},
        onDiscard: {},
        onDone: {}
    )
}
