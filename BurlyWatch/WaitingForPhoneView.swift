// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5: "Fresh install (watch): empty store + no digest renders a
// 'waiting for iPhone' state; arrival of snapshot + digest unlocks the
// routine list." BurlySync doesn't implement that transport yet (later
// milestone) -- this view is what an empty watch store shows until it does.

import SwiftUI

struct WaitingForPhoneView: View {
    var body: some View {
        // Scroll-capable so large Dynamic Type can't clip the instructions
        // unreachably (m2-01 review finding 6.1).
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    // Decorative -- the headline right below it already says
                    // the same thing in words (m2-01 review finding 6.3).
                    .accessibilityHidden(true)
                Text("Waiting for iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    // Stable identifier for UI tests, alongside the literal
                    // copy assertion -- the wording itself is the §5
                    // contract here, so BurlyWatchUITests keeps both
                    // (m2-01 review finding 6.2).
                    .accessibilityIdentifier("waitingForPhoneView.headline")
                Text("Open Burly on your iPhone to sync your routines.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Burly")
    }
}

#Preview {
    NavigationStack {
        WaitingForPhoneView()
    }
}
