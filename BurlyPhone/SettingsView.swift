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
                HevyImportSettingsRow()
            } footer: {
                Text("Bring in workouts from a Hevy CSV export. You'll see what will be added before anything is saved.")
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
