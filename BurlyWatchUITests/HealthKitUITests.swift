// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Spec §4 on the watch simulator with real HealthKit (m3-02..04).
///
/// Opt-in: these answer the system Health authorization sheet, which the
/// acceptance gate cannot pre-grant (`simctl privacy` has no Health
/// service), and the answer persists on the simulator. They skip unless the
/// runner sets `BURLY_HEALTH_UI_TESTS=1` (pass it to `xcodebuild test` as
/// `TEST_RUNNER_BURLY_HEALTH_UI_TESTS=1`). The two prompt tests each need a
/// simulator with no Health answer yet (`simctl erase`); the duration-only
/// test needs the granted one to have run first. The workout count is
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

    /// Recovery matrix row 2 against real HealthKit: with access granted
    /// (by the previous test) but no live workout, Finish saves a
    /// duration-only workout and says it has no sensor data.
    func testWithoutLiveWorkoutSavesDurationOnly() throws {
        let app = launch(health: "noLiveSensors")
        startLegDay(app)
        logOneSet(app)
        endWorkout(app)

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()
        let noSensorData = app.staticTexts["sessionSummary.noSensorData"]
        XCTAssertTrue(noSensorData.waitForExistence(timeout: 20), "Expected the duration-only workout note")
        attachScreenshot(from: app, name: "BurlyWatch-health-noSensorData")
    }

    // MARK: - Steps

    private func launch(health: String = "live") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.healthKey] = health
        app.launch()
        return app
    }

    private func startLegDay(_ app: XCUIApplication) {
        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15), "Expected the seeded 'Leg Day' routine")
        legDayRow.tap()
    }

    /// The Health sheet is system UI, hosted by the watch's Carousel process
    /// rather than the app, so it is found there by Health's own
    /// identifiers.
    ///
    /// On watchOS it opens as a "Health Access" card whose only button is
    /// Review, then one page per access kind (Write Access, Read Access): an
    /// "All Requested Data Below" switch, a switch per type, and a Next cell
    /// at the bottom. Next is only in the accessibility tree once scrolled
    /// into view, so "is the sheet up" is judged by any of its elements, not
    /// by Next. Allow turns every visible switch on; decline leaves them all
    /// off and steps through, which is what a person declining does.
    private func answerHealthPrompt(_ app: XCUIApplication, allow: Bool) {
        let carousel = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        let review = carousel.buttons["Review"]
        let next = carousel.cells["UIA.Health.WatchAuthSheet.ConfigureCell.Button"]
        let accessPage = carousel.navigationBars
            .matching(NSPredicate(format: "identifier IN %@", ["Write Access", "Read Access"])).firstMatch
        let sheetElement = carousel.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'UIA.Health.WatchAuthSheet'")).firstMatch
        let sheetIsUp = { review.exists || accessPage.exists || sheetElement.exists }

        XCTAssertTrue(review.waitForExistence(timeout: 20), "Expected the Health sheet at the first session start")
        review.tap()
        var steps = ["Review"]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, waitFor(timeout: 5, sheetIsUp) {
            if allow,
               let off = carousel.switches.allElementsBoundByIndex
                   .first(where: { "\($0.value ?? "")" == "0" && $0.isHittable }) {
                off.tap()
                steps.append("on")
                continue
            }
            if next.exists, next.isHittable {
                steps.append(next.label)
                next.tap()
                Thread.sleep(forTimeInterval: 1)
            } else {
                carousel.swipeUp()
            }
        }
        attachScreenshot(from: app, name: allow ? "BurlyWatch-health-allowed" : "BurlyWatch-health-declined")
        if sheetIsUp() {
            for (name, host) in [("app", app), ("carousel", carousel)] {
                let tree = XCTAttachment(string: host.debugDescription)
                tree.name = "health-sheet-tree-\(name)"
                tree.lifetime = .keepAlways
                add(tree)
            }
            XCTFail("Health sheet still showing after \(steps)")
        }
        XCTAssertTrue(
            app.buttons["logSetButton"].waitForExistence(timeout: 10),
            "Expected the logging screen after the Health sheet"
        )
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
        // The whole screen, so a system sheet over the app is captured too.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
