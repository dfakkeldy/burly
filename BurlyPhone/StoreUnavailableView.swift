// SPDX-License-Identifier: GPL-3.0-or-later
// Shown when the phone store fails to open (e.g. Application Support
// unavailable), or when a PhoneDemoSeed scenario deliberately fails closed
// (m5-01 review finding 6 -- see PhoneDemoSeed.swift). Not a spec-defined
// state -- just a non-crashing fallback for a real failure the store can
// throw.
//
// ContentView supplies the Retry closure (m5-01 review finding 1): a store
// that failed to open once may open on a second attempt once the
// underlying condition clears, so the unavailable state offers a way back
// in without relaunching. `nil` hides the control, mirroring the watch's
// StoreUnavailableView.

import SwiftUI

struct StoreUnavailableView: View {
    let message: String
    /// `nil` hides the retry control. ContentView always supplies one for
    /// the phone shell (finding 1).
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
