// SPDX-License-Identifier: GPL-3.0-or-later
// Shown only if the on-device watch store fails to open (e.g. Application
// Support unavailable). Not a spec-defined state -- just a non-crashing
// fallback for a real failure `SwiftDataStore.watch()` can throw.

import SwiftUI

struct StoreUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Couldn't open storage")
                .font(.headline)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    StoreUnavailableView(message: "defaultStoreDirectoryUnavailable")
}
