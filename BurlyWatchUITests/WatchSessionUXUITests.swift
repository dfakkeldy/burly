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
            recordFrames(elements, in: screen, label: "entry-\(routine)")
            attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-entry-\(routine)")
            app.terminate()
        }
    }

    /// §2 "Armed: ... +/− micro-buttons appear." They stand in for the reps
    /// control, so arming does not push Log set down: it used to grow the
    /// page by a row and put Log set below the screen exactly when the
    /// lifter had just changed the weight.
    func testLogSetStaysOnScreenWhileTheWeightIsArmed() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        let weightControl = anyElement(app, identifier: "weightControl")
        XCTAssertTrue(waitFor { (weightControl.value as? String)?.contains("locked") == true })
        let screen = screenBounds(app)
        let entryLogFrame = logButton.frame

        weightControl.press(forDuration: 0.6)
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("armed") == true },
            "Expected the long press to arm the weight control"
        )
        let increase = app.buttons["Increase weight"]
        XCTAssertTrue(increase.waitForExistence(timeout: 3), "Expected the armed weight's + button")
        let elements: [(String, XCUIElement)] = [
            ("weight control", weightControl),
            ("weight +", increase),
            ("weight -", app.buttons["Decrease weight"]),
            ("Log set", logButton)
        ]
        for (name, element) in elements {
            XCTAssertTrue(
                waitFor(timeout: 3) { element.exists && screen.contains(element.frame) },
                "Expected the \(name) fully on screen while armed, got \(element.frame) in \(screen)"
            )
        }
        XCTAssertEqual(logButton.frame.minY, entryLogFrame.minY, accuracy: 1, "Arming must not move Log set")
        recordFrames(elements, in: screen, label: "armed")
        attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-armed")

        increase.tap()
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("102.5 kg") == true },
            "Expected + to add one increment, got \(String(describing: weightControl.value))"
        )
        XCTAssertTrue(screen.contains(logButton.frame), "Expected Log set still on screen after adjusting")
        logButton.tap()
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("locked") == true },
            "Expected logging to lock the weight again"
        )
        let repsControl = anyElement(app, identifier: "repsControl")
        XCTAssertTrue(
            repsControl.waitForExistence(timeout: 3),
            "Expected the reps control back once the weight locked"
        )

        // Records, does not assert: what the Digital Crown turns on this
        // screen, locked and armed, is a product call (PR 54).
        let exerciseName = app.staticTexts["exercisePage.name"]
        let lockedBefore = "reps \(String(describing: repsControl.value)), page \(String(describing: exerciseName.value))"
        XCUIDevice.shared.rotateDigitalCrown(delta: 1)
        Thread.sleep(forTimeInterval: 1)
        let lockedAfter = "reps \(String(describing: repsControl.value)), page \(String(describing: exerciseName.value))"
        print("[crown] locked: before \(lockedBefore); after \(lockedAfter)")
        weightControl.press(forDuration: 0.6)
        _ = waitFor { (weightControl.value as? String)?.contains("armed") == true }
        let armedBefore = String(describing: weightControl.value)
        XCUIDevice.shared.rotateDigitalCrown(delta: 1)
        Thread.sleep(forTimeInterval: 1)
        print("[crown] armed: weight before \(armedBefore); after \(String(describing: weightControl.value))")
        attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-crown-armed")
    }

    /// §3: once a set is logged the countdown comes into view, and the
    /// controls stay clear of the clock and the ellipsis button: scrolling
    /// the banner's bottom into view used to put reps + under the ellipsis,
    /// so a tap there opened the actions sheet. Paging to the next exercise
    /// during the rest brings the countdown into view there too.
    func testRestCountdownComesIntoViewWithoutCoveringTheControls() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let row = app.staticTexts["routineRow.Push/Pull.name"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(waitFor(timeout: 10) { exerciseName.exists && exerciseName.label == "Barbell Bench Press" })
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))
        let repsControl = anyElement(app, identifier: "repsControl")
        XCTAssertTrue(repsControl.waitForExistence(timeout: 5))
        // No digest, so nothing to log until reps are entered: the control's
        // trailing + button.
        repsControl.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (repsControl.value as? String) == "1" }, "Expected + to enter 1 rep")
        logButton.tap()

        let screen = screenBounds(app)
        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        assertRestInViewAndControlsClear(app, screen: screen, ellipsis: ellipsis, label: "rest-bench")
        attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-rest-bench")

        // Page to Pull-Up while the rest runs. A page already scrolled to
        // the countdown may take a swipe to reach its end before it pages.
        let onPullUp: () -> Bool = { exerciseName.exists && exerciseName.label == "Pull-Up" }
        var swipes = 0
        while swipes < 3, !onPullUp() {
            app.swipeUp()
            _ = waitFor(timeout: 2, onPullUp)
            swipes += 1
        }
        XCTAssertTrue(onPullUp(), "Expected paging to reach Pull-Up")
        assertRestInViewAndControlsClear(app, screen: screen, ellipsis: ellipsis, label: "rest-pullUp")
        attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-rest-pullUp")
    }

    /// A tap where the back chevron used to be, or an edge swipe, must not
    /// pop the logging screen mid-workout: going back dropped the session's
    /// view model, so the 1 Hz tick and the rest haptics stopped. Leaving
    /// goes only through the actions menu.
    ///
    /// Whether the simulator's edge drag triggers the system back gesture
    /// at all is not established, so the edge swipe here is a smoke check;
    /// an edge swipe on a real watch is the proof for that half.
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
        let remaining = app.staticTexts["restTimer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        let secondsBefore = try restSeconds(from: remaining.value)

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
            waitFor(timeout: 5) {
                guard let now = try? self.restSeconds(from: remaining.value) else { return false }
                return now < secondsBefore
            },
            "The rest countdown must keep running on the logging screen: it read \(secondsBefore) s before the gestures and \(String(describing: remaining.value)) after"
        )

        // The banner counts down on its own timeline, so that alone does
        // not show the view model's tick. Only `SessionViewModel.tick()`
        // locks an armed weight after 3 s idle: the arm lapsing does.
        let weightControl = anyElement(app, identifier: "weightControl")
        weightControl.press(forDuration: 0.6)
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("armed") == true },
            "Expected the long press to arm the weight control"
        )
        XCTAssertTrue(
            waitFor(timeout: 10) { (weightControl.value as? String)?.contains("locked") == true },
            "Expected the session's 1 Hz tick to lock the idle weight, got \(String(describing: weightControl.value))"
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

    /// The countdown and +15 inside the screen, and the weight and reps
    /// controls clear of the ellipsis button and below the clock.
    private func assertRestInViewAndControlsClear(
        _ app: XCUIApplication,
        screen: CGRect,
        ellipsis: XCUIElement,
        label: String,
        line: UInt = #line
    ) {
        let remaining = app.staticTexts["restTimer.remaining"]
        let increase = anyElement(app, identifier: "restTimer.increaseButton")
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected a rest countdown", line: line)
        XCTAssertTrue(
            waitFor(timeout: 5) { screen.contains(remaining.frame) && screen.contains(increase.frame) },
            "Expected the countdown and +15 fully on screen, got \(remaining.frame) and \(increase.frame) in \(screen)",
            line: line
        )
        let weightControl = anyElement(app, identifier: "weightControl")
        let repsControl = anyElement(app, identifier: "repsControl")
        // Let the scroll settle before comparing frames.
        Thread.sleep(forTimeInterval: 0.6)
        let toolbarBottom = ellipsis.exists ? ellipsis.frame.maxY : screen.minY
        for (name, element) in [("weight control", weightControl), ("reps control", repsControl)] {
            XCTAssertTrue(element.exists, "Expected the \(name)", line: line)
            XCTAssertFalse(
                element.frame.intersects(ellipsis.frame),
                "The \(name) \(element.frame) must not sit under the ellipsis button \(ellipsis.frame)",
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                element.frame.minY, toolbarBottom - 1,
                "The \(name) \(element.frame) must sit below the toolbar (ends at \(toolbarBottom))",
                line: line
            )
        }
        recordFrames(
            [
                ("ellipsis", ellipsis), ("weight control", weightControl), ("reps control", repsControl),
                ("Log set", app.buttons["logSetButton"]), ("rest remaining", remaining), ("+15", increase)
            ],
            in: screen,
            label: label
        )
    }

    /// Prints each element's frame, so a run's log records the measured
    /// layout for each watch size.
    private func recordFrames(_ elements: [(String, XCUIElement)], in screen: CGRect, label: String) {
        let lines: [String] = elements.map { (pair: (String, XCUIElement)) -> String in
            pair.1.exists ? "\(pair.0): \(pair.1.frame)" : "\(pair.0): missing"
        }
        print("[frames] \(label) screen \(screen): " + lines.joined(separator: "; "))
    }

    private func restSeconds(from value: Any?) throws -> Int {
        guard let text = value as? String,
              let seconds = Int(text.split(separator: " ", maxSplits: 1).first ?? "") else {
            throw RestLabelError.invalid(String(describing: value))
        }
        return seconds
    }

    private enum RestLabelError: Error {
        case invalid(String)
    }

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
