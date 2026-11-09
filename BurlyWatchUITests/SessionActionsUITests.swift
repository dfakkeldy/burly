// SPDX-License-Identifier: MIT
import XCTest

/// §2's mid-session ellipsis menu: add/remove set, skip, move up/down and
/// the add-exercise picker. Ported from the unmerged m2-04 branch, whose
/// runs saw the pager keep drawing the old pages after a skip, a reorder or
/// an add. Every test here therefore asserts the screen reached after each
/// mutation -- the page's name and its "Exercise N of M" value -- not just
/// that an action row was tappable. Accessibility text is a snapshot of the
/// last render, so a stale value here means the screen did not redraw.
final class SessionActionsUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAndRemoveEmptySetUpdateCounterAndRespectAvailability() throws {
        let app = launchLegDay()
        let setCounter = app.staticTexts["exercisePage.setCounter"]
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 3" })

        openActions(in: app)
        let addSet = app.buttons["sessionActions.addSet"]
        XCTAssertTrue(scrollUntilExists(app, addSet))
        XCTAssertTrue(addSet.isEnabled, "A current exercise should allow adding a set")
        tapRow(addSet, in: app)
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 4" })

        openActions(in: app)
        let removeEmptySet = app.buttons["sessionActions.removeEmptySet"]
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertTrue(removeEmptySet.isEnabled, "An unlogged fourth slot should be removable")
        tapRow(removeEmptySet, in: app)
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 3" })

        let logSet = app.buttons["logSetButton"]
        for expectedCounter in ["Set 2 of 3", "Set 3 of 3", "All 3 sets logged"] {
            // From the second set on, a rest is running and its reveal
            // moves Log set.
            if expectedCounter != "Set 2 of 3" {
                waitForRestInView(app)
            }
            XCTAssertTrue(logSet.waitForExistence(timeout: 5))
            logSet.tap()
            XCTAssertTrue(
                waitFor { setCounter.exists && setCounter.label == expectedCounter },
                "Expected '\(expectedCounter)', got '\(setCounter.label)'"
            )
        }

        openActions(in: app)
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertFalse(
            removeEmptySet.isEnabled,
            "Remove empty set must be disabled when every slot holds a logged set"
        )
    }

    func testSkipReturnsToEmptySessionAndDisablesItemActionsWithoutCurrentItem() throws {
        let app = launchLegDay()

        openActions(in: app)
        let skip = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, skip))
        XCTAssertTrue(skip.isEnabled)
        tapRow(skip, in: app)

        let emptySessionAdd = app.buttons["emptySession.addExercise"]
        XCTAssertTrue(
            emptySessionAdd.waitForExistence(timeout: 5),
            "Skipping Leg Day's only exercise should render the empty-session state"
        )
        XCTAssertFalse(app.staticTexts["exercisePage.name"].exists, "The skipped page must be gone")

        // Each row is checked as soon as it is on screen: the list is lazy,
        // so a row scrolled past is no longer in the tree.
        openActions(in: app)
        let addSet = app.buttons["sessionActions.addSet"]
        XCTAssertTrue(scrollUntilExists(app, addSet))
        XCTAssertFalse(addSet.isEnabled, "Add set must be disabled with no current exercise")
        let removeEmptySet = app.buttons["sessionActions.removeEmptySet"]
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertFalse(removeEmptySet.isEnabled, "Remove empty set must be disabled with no current exercise")
        let skippedAction = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, skippedAction))
        XCTAssertFalse(skippedAction.isEnabled, "Skip must be disabled with no current exercise")
    }

    /// Skip goes to the NEXT visible exercise, not back to the first. The
    /// middle page is reached with Move up rather than by paging: on the
    /// logging screen the Digital Crown drives the focused reps control
    /// (`RepsControlView` is focusable), so `rotateDigitalCrown` changes
    /// reps instead of turning the page, which an earlier run of this test
    /// showed.
    func testSkippingMiddleExerciseAdvancesAndKeepsRenderedOrdinalsDense() throws {
        let app = launchLegDay()
        let exerciseName = app.staticTexts["exercisePage.name"]

        addExercise(named: "Barbell Bench Press", in: app)
        XCTAssertTrue(waitFor { exerciseName.exists && exerciseName.label == "Barbell Bench Press" })
        addExercise(named: "Barbell Curl", in: app)
        XCTAssertTrue(waitFor { exerciseName.exists && exerciseName.label == "Barbell Curl" })
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 3 of 3" },
            "Expected the second add to render as the third page, got \(String(describing: exerciseName.value))"
        )

        // Back Squat, Barbell Curl, Barbell Bench Press: Barbell Curl is now the
        // middle page, and still the current one.
        openActions(in: app)
        let moveUp = app.buttons["sessionActions.moveUp"]
        XCTAssertTrue(scrollUntilExists(app, moveUp))
        tapRow(moveUp, in: app)
        XCTAssertTrue(
            waitFor { exerciseName.exists && (exerciseName.value as? String) == "Exercise 2 of 3" },
            "Expected Barbell Curl on the middle page, got \(String(describing: exerciseName.value))"
        )
        XCTAssertEqual(exerciseName.label, "Barbell Curl")

        openActions(in: app)
        let skip = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, skip))
        tapRow(skip, in: app)

        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Barbell Bench Press" },
            "Skipping the middle exercise must advance to the next visible exercise, not restart the workout"
        )
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 2 of 2" },
            "After skipping the middle of three, the last visible page must be Exercise 2 of 2, got \(String(describing: exerciseName.value))"
        )
    }

    func testMoveUpChangesTheRenderedPagerOrder() throws {
        let app = launchLegDay()
        let exerciseName = app.staticTexts["exercisePage.name"]

        addExercise(named: "Barbell Bench Press", in: app)
        XCTAssertTrue(waitFor { exerciseName.exists && exerciseName.label == "Barbell Bench Press" })
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 2 of 2" },
            "The added exercise must render after Back Squat, got \(String(describing: exerciseName.value))"
        )

        openActions(in: app)
        let moveUp = app.buttons["sessionActions.moveUp"]
        XCTAssertTrue(scrollUntilExists(app, moveUp))
        XCTAssertTrue(moveUp.isEnabled)
        tapRow(moveUp, in: app)

        XCTAssertTrue(
            waitFor { exerciseName.exists && (exerciseName.value as? String) == "Exercise 1 of 2" },
            "Move up must change the rendered page from second to first, got \(String(describing: exerciseName.value))"
        )
        XCTAssertTrue(waitFor { exerciseName.label == "Barbell Bench Press" })

        openActions(in: app)
        let moveDown = app.buttons["sessionActions.moveDown"]
        XCTAssertTrue(scrollUntilExists(app, moveDown))
        XCTAssertTrue(moveDown.isEnabled)
        tapRow(moveDown, in: app)
        XCTAssertTrue(
            waitFor { exerciseName.exists && (exerciseName.value as? String) == "Exercise 2 of 2" },
            "Move down must return the exercise to the second page, got \(String(describing: exerciseName.value))"
        )
    }

    /// §2 picker order: recents first. Back Squat is both in this session
    /// and has the seeded digest, so it heads the add picker ahead of
    /// alphabetically earlier curated rows.
    func testAddExercisePickerPutsRecentExerciseFirstAndPlaceholderRoutesToNewPage() throws {
        let app = launchLegDay()
        let exerciseName = app.staticTexts["exercisePage.name"]

        openActions(in: app)
        let addExercise = app.buttons["sessionActions.addExercise"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()

        let firstCatalogRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'exercisePicker.row.'")
        ).element(boundBy: 0)
        XCTAssertTrue(firstCatalogRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitFor { firstCatalogRow.label == "Back Squat" },
            "The recently used exercise must precede alphabetically earlier curated rows, got '\(firstCatalogRow.label)'"
        )

        let placeholder = app.buttons["exercisePicker.addPlaceholder"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        placeholder.tap()
        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Custom exercise" },
            "Custom (name later) should create and route to the new placeholder page"
        )
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 2 of 2" },
            "The placeholder must render as the second page, got \(String(describing: exerciseName.value))"
        )
    }

    // MARK: - Helpers

    private func launchLegDay() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDay = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDay.waitForExistence(timeout: 15))
        legDay.tap()
        XCTAssertTrue(app.staticTexts["exercisePage.name"].waitForExistence(timeout: 10))
        return app
    }

    private func openActions(in app: XCUIApplication) {
        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
    }

    private func addExercise(named name: String, in app: XCUIApplication) {
        openActions(in: app)
        let addExercise = app.buttons["sessionActions.addExercise"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()
        selectPickerExercise(named: name, in: app)
    }

    /// watchOS exposes `.searchable` through its dictation/scribble UI, not
    /// as an XCUI search field, so scroll the real list until the row is
    /// realized and hittable.
    private func selectPickerExercise(
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let exercise = app.buttons["exercisePicker.row.\(name)"]
        XCTAssertTrue(
            app.buttons["exercisePicker.addPlaceholder"].waitForExistence(timeout: 5)
                || exercise.waitForExistence(timeout: 1),
            "Expected the exercise picker to open",
            file: file,
            line: line
        )
        for _ in 0..<40 {
            if exercise.exists && exercise.isHittable {
                tapRow(exercise, in: app, file: file, line: line)
                return
            }
            dragUpOneRow(in: app)
        }
        XCTFail("Expected \(name) in the exercise picker", file: file, line: line)
    }

    /// Full-screen watch swipes jump from rows 1-4 to rows 6-9, so a lazy
    /// row at position 5 is never realized. Move roughly one row at a time.
    private func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement, maxAttempts: Int = 20) -> Bool {
        for _ in 0..<maxAttempts {
            if element.exists {
                Thread.sleep(forTimeInterval: 0.4)
                return true
            }
            dragUpOneRow(in: app)
        }
        return element.exists
    }

    /// Taps an action row on the part of it that shows below the sheet's
    /// navigation bar. A drag can leave a row realized but half under the
    /// bar (the Skip row came to rest at y 25-81 under a 62 pt bar):
    /// XCUITest still calls it hittable, but `tap()` at its centre lands on
    /// the bar, which closes the sheet without running the action. That
    /// made a skip look like a pager that never redrew.
    private func tapRow(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let barBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 62
        let screen = app.windows.firstMatch.exists ? app.windows.firstMatch.frame : app.frame
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
            // Barely showing: nudge it toward the middle, slowly and with a
            // hold at the end so the list does not fling past it.
            let towardMiddle: CGFloat = frame.midY < screen.midY ? 0.15 : -0.15
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + towardMiddle))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("Could not tap \(element) below the navigation bar", file: file, line: line)
    }

    private func dragUpOneRow(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// After a Log set that starts a rest, waits for the page's reveal to
    /// finish: the countdown fully on screen and Log set no longer moving.
    /// The reveal lands a moment after the tap; a tap sent before it lands
    /// hits whatever has scrolled under it, and on the hosted simulator
    /// that was the countdown, whose tap skips the rest.
    private func waitForRestInView(_ app: XCUIApplication, line: UInt = #line) {
        let screen = screenBounds(app)
        let remaining = app.staticTexts["restTimer.remaining"]
        let logButton = app.buttons["logSetButton"]
        var lastLogFrame = CGRect.null
        let settled = waitFor(timeout: 10) {
            guard remaining.exists, screen.contains(remaining.frame) else { return false }
            let logFrame = logButton.frame
            defer { lastLogFrame = logFrame }
            return logFrame == lastLogFrame
        }
        XCTAssertTrue(
            settled,
            "Expected the rest countdown to come into view after Log set, got \(remaining.frame) in \(screen)",
            line: line
        )
    }

    /// The visible screen: the app's window, or the application element's
    /// own frame if watchOS reports no window.
    private func screenBounds(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        if window.exists, !window.frame.isEmpty { return window.frame }
        return app.frame
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
}
