// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// The logging screen as a tester first meets it: everything needed to log
/// a set is on screen the moment an exercise opens, and nothing short of
/// the actions menu takes the lifter out of a workout in progress.
///
/// "On screen" means inside the visible screen, not merely in the
/// accessibility tree: `exists` is true for rows below the fold, which is
/// how the old layout's off-screen Log set button passed every test.
final class WatchSessionUXUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// §2: header, ghost row, weight, reps, then the one primary Log set
    /// button -- all visible on entry with no scrolling, for an exercise
    /// with a digest (real numbers) and one without (placeholders).
    func testLogSetAndControlsAreOnScreenWhenAnExerciseOpens() throws {
        for (routine, exercise) in [("Leg Day", "Back Squat"), ("Push/Pull", "Barbell Bench Press")] {
            let app = XCUIApplication()
            app.launchEnvironment[Self.scenarioKey] = "routines"
            app.launch()

            let row = app.staticTexts["routineRow.\(routine).name"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Expected the seeded '\(routine)' routine")
            row.tap()

            let exerciseName = app.staticTexts["exercisePage.name"]
            XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
            XCTAssertEqual(exerciseName.label, exercise)
            let logButton = app.buttons["logSetButton"]
            XCTAssertTrue(logButton.waitForExistence(timeout: 5))

            let screen = screenBounds(app)
            let elements: [(String, XCUIElement)] = [
                ("exercise name", exerciseName),
                ("set counter", app.staticTexts["exercisePage.setCounter"]),
                ("ghost row", app.staticTexts["exercisePage.ghost"]),
                ("weight control", anyElement(app, identifier: "weightControl")),
                ("reps control", anyElement(app, identifier: "repsControl")),
                ("Log set", logButton)
            ]
            for (name, element) in elements {
                XCTAssertTrue(
                    waitFor(timeout: 3) { element.exists && screen.contains(element.frame) },
                    "\(exercise): expected the \(name) fully on screen on entry, got \(element.frame) in \(screen)"
                )
            }
            XCTAssertGreaterThanOrEqual(logButton.frame.height, 44, "Log set must keep a 44 pt tall target")
            attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-entry-\(routine)")
            app.terminate()
        }
    }

    /// A tap where the back chevron used to be, or an edge swipe, must not
    /// pop the logging screen mid-workout: going back dropped the session's
    /// view model, so the 1 Hz tick and the rest haptics stopped. Leaving
    /// goes only through the actions menu.
    func testBackGesturesCannotLeaveAnActiveSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))
        logButton.tap()
        XCTAssertTrue(app.staticTexts["restTimer.remaining"].waitForExistence(timeout: 5))

        // The top-leading corner, where the system back chevron sits.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.14)).tap()
        XCTAssertFalse(
            legDayRow.waitForExistence(timeout: 2),
            "A tap in the top-leading corner must not leave the workout"
        )
        XCTAssertTrue(exerciseName.exists, "Expected to stay on the logging screen")

        // An edge swipe from the leading edge.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertFalse(
            legDayRow.waitForExistence(timeout: 2),
            "An edge swipe must not leave the workout"
        )
        XCTAssertTrue(exerciseName.exists, "Expected to stay on the logging screen")
        XCTAssertTrue(
            app.staticTexts["restTimer.remaining"].exists,
            "The rest countdown must keep running on the logging screen"
        )

        // The way out is the actions menu: End workout -> Finish -> Done.
        anyElement(app, identifier: "ellipsisMenu").tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
        tapRow(endWorkout, in: app)
        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 10), "Expected Done to return to the routine list")
    }

    // MARK: - Helpers

    /// The visible screen: the app's window, or the application element's
    /// own frame if watchOS reports no window.
    private func screenBounds(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        if window.exists, !window.frame.isEmpty { return window.frame }
        return app.frame
    }

    private func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement, maxAttempts: Int = 20) -> Bool {
        for _ in 0..<maxAttempts {
            if element.exists {
                Thread.sleep(forTimeInterval: 0.4)
                return true
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists
    }

    /// Taps a list row on the part of it below the sheet's navigation bar:
    /// a row half under the bar reads as hittable, but a tap at its centre
    /// lands on the bar and closes the sheet (`SessionActionsUITests.tapRow`).
    private func tapRow(_ element: XCUIElement, in app: XCUIApplication, line: UInt = #line) {
        let barBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 62
        let screen = screenBounds(app)
        for _ in 0..<4 {
            guard element.exists else { break }
            let frame = element.frame
            let top = max(frame.minY, barBottom)
            let bottom = min(frame.maxY, screen.maxY)
            if bottom - top >= 16 {
                let dy = ((top + bottom) / 2 - frame.minY) / frame.height
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
                return
            }
            let towardMiddle: CGFloat = frame.midY < screen.midY ? 0.15 : -0.15
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + towardMiddle))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("Could not tap \(element) below the navigation bar", line: line)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
