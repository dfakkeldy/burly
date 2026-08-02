// SPDX-License-Identifier: GPL-3.0-or-later
// The shared empty-state / failure layout for the tab shell (spec m5-01):
// each tab renders honest copy for zero data, and load failures render the
// same layout with a retry. Scroll-capable so a long message or large
// Dynamic Type can't clip content unreachably (m2-01 review finding 6.1,
// same rationale as the watch's StoreUnavailableView).

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    /// Identifiers are exposed as "<prefix>.emptyState.heading" /
    /// ".message" / ".retryButton", so each tab scopes them by its own
    /// prefix and tests never couple to copy.
    let identifierPrefix: String
    /// `nil` hides the retry control (a store that failed to open at the
    /// root has nothing yet to retry against).
    var onRetry: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    // Decorative -- the heading right below it already says
                    // the same thing in words.
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("\(identifierPrefix).emptyState.heading")
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(identifierPrefix).emptyState.message")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .accessibilityIdentifier("\(identifierPrefix).emptyState.retryButton")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    EmptyStateView(
        icon: "clock.arrow.circlepath",
        title: "No history yet",
        message: "Workouts you finish will show up here, starting with your first session.",
        identifierPrefix: "historyTab"
    )
}
