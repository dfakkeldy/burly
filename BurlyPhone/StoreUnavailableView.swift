// SPDX-License-Identifier: GPL-3.0-or-later
// Shown when the phone store fails to open (e.g. Application Support
// unavailable). Not a spec-defined state -- just a non-crashing fallback for
// a real failure the store can throw, mirroring the watch shell's
// StoreUnavailableView. A store that failed to open at all has nothing yet
// to retry against, so there is no retry control here; per-tab load failures
// render EmptyStateView with one instead.

import SwiftUI

struct StoreUnavailableView: View {
    let message: String

    var body: some View {
        // Scroll-capable so a long error message or large Dynamic Type
        // can't clip content unreachably (m2-01 review finding 6.1).
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    // Decorative -- the heading right below it already says
                    // the same thing in words.
                    .accessibilityHidden(true)
                Text("Couldn't open storage")
                    .font(.headline)
                    .accessibilityIdentifier("storeUnavailableView.heading")
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("storeUnavailableView.message")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    StoreUnavailableView(message: "defaultStoreDirectoryUnavailable")
}
