// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5: "Fresh install (watch): empty store + no digest renders a
// 'waiting for iPhone' state; arrival of snapshot + digest unlocks the
// routine list." BurlySync doesn't implement that transport yet (later
// milestone) -- this view is what an empty watch store shows until it does.

import SwiftUI

struct WaitingForPhoneView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Waiting for iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Open Burly on your iPhone to sync your routines.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Burly")
    }
}

#Preview {
    NavigationStack {
        WaitingForPhoneView()
    }
}
