// SPDX-License-Identifier: GPL-3.0-or-later
// m2-06 review finding 2.1: the targeted recovery for
// `WatchHomeViewModel.LoadState.unreadableSession` -- see that file's doc
// for why this exists as its own state rather than folding into `.failed`,
// and why the single button here is deliberately not §2's normal
// double-confirm Discard.
import SwiftUI

struct UnreadableSessionView: View {
    let onDiscard: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Workout data couldn't be read")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("unreadableSession.heading")
                Text("This workout's saved data is damaged and can't be resumed or reviewed. Discard it to keep using Burly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Discard unreadable workout", role: .destructive, action: onDiscard)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("unreadableSession.discardButton")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Burly")
    }
}

#Preview {
    NavigationStack {
        UnreadableSessionView(onDiscard: {})
    }
}
