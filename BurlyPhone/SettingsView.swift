// SPDX-License-Identifier: GPL-3.0-or-later
// Settings tab (spec m5-01). Rows are static placeholders where their
// features are later tasks -- the spec explicitly allows this ("settings
// rows may be static placeholders where their features are later tasks"):
// there is no behavior beyond the rows themselves.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section {
                Label("Import from Hevy", systemImage: "tray.and.arrow.down")
                    .accessibilityIdentifier("settingsTab.importRow")
            } footer: {
                Text("Importing your Hevy routines and history is coming in a later update.")
            }

            Section("About") {
                LabeledContent("Version", value: versionString)
                    .accessibilityIdentifier("settingsTab.versionRow")
            }
        }
        .navigationTitle("Settings")
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
