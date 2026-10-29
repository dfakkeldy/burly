// SPDX-License-Identifier: GPL-3.0-or-later
// Entry points into the Hevy import screen (spec §8/§9; task m7-02).
//
// The import screen is presented by MainTabView, which owns the store's
// view model; the welcome path and the Settings row both ask it to. The
// Settings row reaches it through an environment action rather than a new
// SettingsView initializer parameter or a push inside Settings' own stack,
// so both entry points present the same sheet over the tab shell.

import SwiftUI

/// Asks the tab shell to present the Hevy import screen.
struct PresentHevyImportAction: Sendable {
    let present: @MainActor @Sendable () -> Void

    @MainActor
    func callAsFunction() {
        present()
    }
}

extension EnvironmentValues {
    /// No-op outside the tab shell (previews of SettingsView alone).
    @Entry var presentHevyImport = PresentHevyImportAction(present: {})
}

/// Settings' "Import from Hevy" row (§9: Settings includes "Hevy import
/// (§8)"). Keeps m5-01's `settingsTab.importRow` identifier.
struct HevyImportSettingsRow: View {
    @Environment(\.presentHevyImport) private var presentHevyImport

    var body: some View {
        Button {
            presentHevyImport()
        } label: {
            Label("Import from Hevy", systemImage: "tray.and.arrow.down")
        }
        .accessibilityHint("Opens the Hevy CSV import")
        .accessibilityIdentifier("settingsTab.importRow")
    }
}
