// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m4-06 paired-simulator acceptance, watch half: the routine the phone
/// half built arrives over WatchConnectivity, and a session logged against
/// it is finished so the outbox sends it back. See
/// BurlyPhoneUITests/PairedSyncUITests.swift and Scripts/paired-sync-sim.sh.
///
/// Opt-in (`BURLY_PAIRED_SYNC_UI_TESTS=1`): it needs a paired phone that
/// has just pushed `BURLY_PAIRED_ROUTINE`.
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

    func testPhoneRoutineArrivesAndSessionGoesBack() throws {
        // No UI-test scenario: the on-device store, with sync running.
        let app = XCUIApplication()
        app.launch()

        let routineRow = app.staticTexts["routineRow.\(routineName).name"]
        XCTAssertTrue(
            routineRow.waitForExistence(timeout: 120),
            "Expected the phone's routine '\(routineName)' on the watch"
        )
        attachScreenshot(from: app, name: "PairedSync-watch-routineArrived")
        routineRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Barbell Bench Press")
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))
        logButton.tap()

        let ellipsis = app.descendants(matching: .any).matching(identifier: "ellipsisMenu").firstMatch
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        for _ in 0..<8 where !endWorkout.exists { app.swipeUp() }
        endWorkout.tap()

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 10), "Expected Finish to store the session")
        attachScreenshot(from: app, name: "PairedSync-watch-sessionSaved")
        doneButton.tap()

        // Keep the app up while WatchConnectivity takes the user-info
        // transfer; the outbox retries on the next activation regardless.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
