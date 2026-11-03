// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// The App Store screenshots for Apple Watch, not an acceptance test: one
/// pass through WatchDemoSeed's synthetic `storeScreenshots` scenario,
/// attaching each screen under the name its file gets in
/// fastlane/screenshots/en-US. Scripts/capture-store-screenshots.sh runs it
/// on the "Burly Watch S11 46mm" simulator (416 × 496, App Store Connect's
/// Series 10/11 slot) with BURLY_STORE_SCREENSHOTS=1. Every other run skips
/// it, so the acceptance gate never pays for it.
///
/// The scenario leaves today's Legs workout open with every set logged, so
/// the flow runs in an order that keeps every number real: decline Resume
/// to its summary and Finish it (a real duration and volume), Done back to
/// the routine list, then start Push for a prefilled first set and log it
/// for the rest countdown. The en-US screenshots are in pounds, which a
/// seeded launch takes from BURLY_WATCH_UI_TEST_DISPLAY_UNIT because it has
/// no sync to carry the phone's unit.
///
/// Waits go through stable identifiers and nothing asserts layout, so a
/// screen that reflows still captures.
final class StoreScreenshotsUITests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BURLY_STORE_SCREENSHOTS"] == "1",
            "App Store screenshots run only from Scripts/capture-store-screenshots.sh (BURLY_STORE_SCREENSHOTS=1)"
        )
        continueAfterFailure = false
    }

    func testCaptureStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BURLY_WATCH_UI_TEST_SCENARIO"] = "storeScreenshots"
        app.launchEnvironment["BURLY_WATCH_UI_TEST_DISPLAY_UNIT"] = "lb"
        app.launch()

        // Today's Legs: its summary, then saved.
        let notNow = app.buttons["resumeSession.notNowButton"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 20), "Expected the open Legs workout's Resume screen")
        let screen = screenBounds(app)
        notNow.tap()

        let heading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(waitFor(timeout: 10) { heading.exists && heading.label == "End workout?" }, "Expected the summary")
        // 265×25 + 185×24 + 45×30 + 85×36 + 165×36 = 21415 lb.
        let volume = anyElement(app, identifier: "sessionSummary.volume")
        XCTAssertTrue(volume.label.contains("21415 lb"), "Expected 21415 lb of volume, got '\(volume.label)'")
        capture(app, "extra_watch_end_workout")

        app.buttons["sessionSummary.finishButton"].tap()
        XCTAssertTrue(waitFor(timeout: 10) { heading.exists && heading.label == "Workout saved" }, "Expected Finish to save")
        // The summary runs past the bottom edge. Scroll just far enough that
        // its last line of text is whole; Done then peeks in below it.
        let beatLastTime = app.staticTexts["sessionSummary.beatLastTime"]
        XCTAssertTrue(beatLastTime.waitForExistence(timeout: 5), "Expected Squat and RDL to beat last time")
        for _ in 0..<4 where beatLastTime.frame.maxY > screen.maxY - 6 {
            drag(app, by: max(24, beatLastTime.frame.maxY - screen.maxY + 14))
        }
        XCTAssertTrue(screen.contains(beatLastTime.frame), "Expected the whole summary text on screen")
        capture(app, "04_watch_summary")

        // The routine list, Legs now done today.
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        let push = app.staticTexts["routineRow.Push.name"]
        XCTAssertTrue(push.waitForExistence(timeout: 10), "Expected the routine list")
        capture(app, "01_watch_routines")

        // Push opens on the bench press, prefilled from last time.
        push.tap()
        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            waitFor(timeout: 10) { exerciseName.exists && exerciseName.label == "Barbell Bench Press" },
            "Expected the logging screen on the bench press"
        )
        let ghost = app.staticTexts["exercisePage.ghost"]
        XCTAssertTrue(waitFor { ghost.exists && ghost.label == "Last: 185.0 lb × 5" }, "Expected the ghost row in pounds")
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))
        capture(app, "02_watch_logging")

        // Logging it starts the rest countdown, which the page scrolls to.
        logButton.tap()
        let remaining = app.staticTexts["restTimer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected the rest countdown")
        XCTAssertTrue(waitFor(timeout: 3) { screen.contains(remaining.frame) }, "Expected the countdown on screen")
        capture(app, "03_watch_rest")
    }

    // MARK: - Helpers

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Moves the content up by `distance` points with a slow, held drag, so
    /// it stops where the finger does instead of flinging.
    private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 0, dy: -distance))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenBounds(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        if window.exists, !window.frame.isEmpty { return window.frame }
        return app.frame
    }

    /// The app's screen after a moment for any push or scroll to finish.
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
