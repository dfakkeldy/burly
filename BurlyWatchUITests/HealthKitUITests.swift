// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Spec §4 on the watch simulator with real HealthKit (m3-02..04).
///
/// Opt-in: these answer the system Health authorization sheet, which the
/// acceptance gate cannot pre-grant (`simctl privacy` has no Health
/// service), and the answer persists on the simulator. They skip unless the
/// runner sets `BURLY_HEALTH_UI_TESTS=1` (pass it to `xcodebuild test` as
/// `TEST_RUNNER_BURLY_HEALTH_UI_TESTS=1`). Each test needs the app's Health
/// authorization reset first (uninstall the app), and the workout count is
/// checked outside the test against the simulator's Health database: a UI
/// test cannot query HealthKit as the app.
final class HealthKitUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"
    private static let healthKey = "BURLY_WATCH_UI_TEST_HEALTH"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BURLY_HEALTH_UI_TESTS"] == "1",
            "Real-HealthKit tests run only when BURLY_HEALTH_UI_TESTS=1"
        )
    }

    /// Granted path: the first session start asks, a finished session is
    /// saved, and a second session that is discarded saves nothing.
    func testGrantedSessionFinishesAndDiscardedSessionDoesNot() throws {
        let app = launch()
        startLegDay(app)
        answerHealthPrompt(app, allow: true)
        logOneSet(app)
        endWorkout(app)
        finish(app)

        startLegDay(app)
        logOneSet(app)
        discard(app)
    }

    /// §4 acceptance #4: declined authorization still completes the
    /// session, persists its sets, and shows no Health error.
    func testDeclinedAuthorizationStillFinishesSession() throws {
        let app = launch()
        startLegDay(app)
        answerHealthPrompt(app, allow: false)
        logOneSet(app)
        endWorkout(app)

        let setsRow = anyElement(app, identifier: "sessionSummary.sets")
        XCTAssertTrue(setsRow.waitForExistence(timeout: 5))
        XCTAssertTrue(setsRow.label.contains("1"), "Expected the logged set in the summary, got '\(setsRow.label)'")
        finish(app)
        XCTAssertFalse(app.staticTexts["sessionSummary.saveError"].exists, "Declined Health must not surface an error")
        XCTAssertFalse(app.staticTexts["sessionSummary.noSensorData"].exists)
    }

    // MARK: - Steps

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.healthKey] = "live"
        app.launch()
        return app
    }

    private func startLegDay(_ app: XCUIApplication) {
        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15), "Expected the seeded 'Leg Day' routine")
        legDayRow.tap()
    }

    /// The Health sheet is system UI hosted over the app; its button labels
    /// are matched by text because it carries no identifiers of ours.
    private func answerHealthPrompt(_ app: XCUIApplication, allow: Bool) {
        let logButton = app.buttons["logSetButton"]
        let deadline = Date().addingTimeInterval(20)
        var answered = false
        while Date() < deadline {
            if allow, tapFirst(app, labels: ["Turn On All", "Turn On All Categories"]) {
                answered = true
            }
            let finalLabels = allow ? ["Allow", "Done", "Next"] : ["Don’t Allow", "Don't Allow", "Not Now", "Cancel"]
            if tapFirst(app, labels: finalLabels) {
                answered = true
                if !allow || logButton.waitForExistence(timeout: 2) { break }
            }
            if answered, logButton.exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attachScreenshot(from: app, name: allow ? "BurlyWatch-health-allowed" : "BurlyWatch-health-declined")
        XCTAssertTrue(answered, "Expected the Health authorization sheet at the first session start")
        XCTAssertTrue(logButton.waitForExistence(timeout: 10), "Expected the logging screen after the Health sheet")
    }

    private func tapFirst(_ app: XCUIApplication, labels: [String]) -> Bool {
        for label in labels {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return true
            }
        }
        return false
    }

    private func logOneSet(_ app: XCUIApplication) {
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10), "Expected the logging screen")
        logButton.tap()
    }

    private func openActions(_ app: XCUIApplication) {
        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
    }

    private func endWorkout(_ app: XCUIApplication) {
        openActions(app)
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
        endWorkout.tap()
    }

    private func finish(_ app: XCUIApplication) {
        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        let heading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(
            waitFor(timeout: 20) { heading.exists && heading.label == "Workout saved" },
            "Expected Finish to save the session"
        )
        attachScreenshot(from: app, name: "BurlyWatch-health-saved")
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
    }

    private func discard(_ app: XCUIApplication) {
        openActions(app)
        let discardAction = app.buttons["sessionActions.discardWorkout"]
        XCTAssertTrue(scrollUntilExists(app, discardAction), "Expected to be able to scroll to 'Discard workout'")
        discardAction.tap()
        let stepOne = app.buttons["discardConfirm.stepOneButton"]
        XCTAssertTrue(stepOne.waitForExistence(timeout: 5))
        stepOne.tap()
        let stepTwo = app.buttons["discardConfirm.stepTwoButton"]
        XCTAssertTrue(stepTwo.waitForExistence(timeout: 5))
        stepTwo.tap()
        XCTAssertTrue(
            app.staticTexts["routineRow.Leg Day.name"].waitForExistence(timeout: 10),
            "Expected Discard to return to the routine list"
        )
    }

    // MARK: - Helpers

    private func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement, maxAttempts: Int = 12) -> Bool {
        for _ in 0..<maxAttempts {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
