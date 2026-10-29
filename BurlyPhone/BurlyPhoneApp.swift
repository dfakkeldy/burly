// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct BurlyPhoneApp: App {
    init() {
        // Before any view reads the preference; a no-op outside DEBUG UI
        // test launches (see DisplayUnitPreference).
        DisplayUnitPreference.resetForUITestsIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
