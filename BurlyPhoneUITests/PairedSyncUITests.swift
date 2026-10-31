// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m4-06 paired-simulator check, phone half: the real app on its real
/// store builds a routine named `BURLY_PAIRED_ROUTINE`, and sync hands the
/// snapshot to WatchConnectivity. Scripts/paired-sync-sim.sh runs it and
/// then checks that the paired watch applied the phone's digest.
///
/// It stops there because Simulator never delivers a WatchConnectivity
/// file to the receiving app, so the snapshot cannot reach the watch UI
/// between simulators; that half needs paired devices.
///
/// Opt-in (`BURLY_PAIRED_SYNC_UI_TESTS=1`): it needs a paired watch with
/// BurlyWatch installed, and it leaves data in the on-device store.
final class PairedSyncUITests: XCTestCase {

    private var routineName = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["BURLY_PAIRED_SYNC_UI_TESTS"] == "1",
            "Paired-simulator tests run only when BURLY_PAIRED_SYNC_UI_TESTS=1"
        )
        routineName = try XCTUnwrap(environment["BURLY_PAIRED_ROUTINE"], "BURLY_PAIRED_ROUTINE names the routine")
        continueAfterFailure = false
    }

    func testBuildRoutineForWatch() throws {
        let app = launchRealApp()

        app.tabBars.buttons["Routines"].tap()
        let newRoutine = app.buttons["routinesTab.newRoutineButton"]
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 15))
        newRoutine.tap()
        let nameField = app.textFields["routineCreator.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(routineName)
        app.buttons["routineCreator.createButton"].tap()

        // Barbell Bench Press, by its frozen curated catalog ID.
        let addExercise = app.buttons["routineEditor.addExerciseButton"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 10))
        addExercise.tap()
        let bench = app.buttons["catalog.addExercise.10000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(bench.waitForExistence(timeout: 10))
        bench.tap()
        app.buttons["routineEditor.saveButton"].tap()

        // Stay in the foreground past the catalog debounce so the snapshot
        // transfer is queued before the test runner ends the app.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        attachScreenshot(from: app, name: "PairedSync-phone-routineBuilt")
    }

    /// No UI-test scenario: the on-device store, with sync running.
    private func launchRealApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()
        return app
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
