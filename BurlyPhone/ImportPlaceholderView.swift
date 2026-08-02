// SPDX-License-Identifier: GPL-3.0-or-later
// The clearly-labeled placeholder the welcome's "Import from Hevy" leads to
// (spec m5-01). The real import UI is a later task; this screen exists so
// the first-launch path has an honest destination that says what it is and
// what is coming, instead of a dead tap.

import SwiftUI

struct ImportPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                // Decorative -- the heading below says the same thing.
                .accessibilityHidden(true)
            Text("Import from Hevy")
                .font(.headline)
                .accessibilityIdentifier("importPlaceholderView.heading")
            Text("Importing your Hevy routines and history is coming in a later update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("importPlaceholderView.message")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .navigationTitle("Import from Hevy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ImportPlaceholderView()
    }
}
