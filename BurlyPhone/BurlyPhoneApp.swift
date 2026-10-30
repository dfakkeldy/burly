// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@main
struct BurlyPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    init() {
        // Before any view reads the preferences; no-ops outside DEBUG UI
        // test launches (see DisplayUnitPreference).
        DisplayUnitPreference.resetForUITestsIfRequested()
        RestDefaultPreference.resetForUITestsIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.model)
        }
    }
}

/// Owns `PhoneAppModel` so sync starts at launch, including the background
/// launches Watch Connectivity uses to deliver a session (see PhoneAppModel).
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    let model = PhoneAppModel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        model.launch()
        return true
    }
}
