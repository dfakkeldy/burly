// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m4-06 paired-simulator acceptance, phone half: the real app on its real
/// store, talking to a paired watch simulator over WatchConnectivity. Run
/// by Scripts/paired-sync-sim.sh, which interleaves these with the watch
/// half (BurlyWatchUITests/PairedSyncUITests.swift):
///
///  1. `testBuildRoutineForWatch` builds a routine named `BURLY_PAIRED_ROUTINE`.
///  2. The watch half waits for it, logs a set and finishes.
///  3. `testWatchSessionReachesHistory` waits for that session in History.
///
/// Opt-in (`BURLY_PAIRED_SYNC_UI_TESTS=1`): they need a paired watch with
/// BurlyWatch installed, and they leave data in the on-device store.
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

    func testWatchSessionReachesHistory() throws {
        let app = launchRealApp()

        app.tabBars.buttons["History"].tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyTab.sessionRow.' AND label CONTAINS %@", routineName)
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 120),
            "Expected the session logged on the watch for '\(routineName)' in History"
        )
        attachScreenshot(from: app, name: "PairedSync-phone-historyHasWatchSession")
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
