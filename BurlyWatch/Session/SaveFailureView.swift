// SPDX-License-Identifier: GPL-3.0-or-later
// m2-03 review findings 6-9: a lifter mid-workout must never be lied to
// about whether their sets are saved. Any failed `saveActiveSession` /
// `createExercise` during ordinary logging or a mid-session edit blocks
// the whole logging screen here rather than letting the UI imply the
// mutation was durable -- `SessionViewModel` never folds a failed attempt
// into the engine it reads from, so nothing behind this view is showing a
// save that didn't happen.
import SwiftUI

struct SaveFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Couldn't save")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("saveFailure.heading")
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("saveFailure.message")
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("saveFailure.retryButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    SaveFailureView(message: "Injected failure for testing: saveActiveSession", onRetry: {})
}
