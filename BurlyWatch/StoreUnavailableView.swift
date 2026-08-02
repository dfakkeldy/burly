// SPDX-License-Identifier: GPL-3.0-or-later
// Shown when the watch store fails to open, or when a load against an
// already-open store fails (e.g. Application Support unavailable, or a
// WatchDemoSeed scenario that deliberately fails closed -- see
// WatchDemoSeed.swift). Not a spec-defined state -- just a non-crashing
// fallback for a real failure the store or its seed can throw.

import SwiftUI

struct StoreUnavailableView: View {
    let message: String
    /// `nil` hides the retry control. ContentView supplies one for a
    /// `WatchHomeViewModel.LoadState.failed` (m2-01 review finding 4.1); a
    /// store that failed to open at all (RootView) has nothing yet to
    /// retry against.
    var onRetry: (() -> Void)? = nil

    var body: some View {
        // Scroll-capable so a long error message or large Dynamic Type
        // can't clip content unreachably (m2-01 review finding 6.1).
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    // Decorative -- the heading right below it already says
                    // the same thing in words (m2-01 review finding 6.3).
                    .accessibilityHidden(true)
                Text("Couldn't open storage")
                    .font(.headline)
                    .accessibilityIdentifier("storeUnavailableView.heading")
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("storeUnavailableView.message")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .accessibilityIdentifier("storeUnavailableView.retryButton")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    StoreUnavailableView(message: "defaultStoreDirectoryUnavailable") {}
}
