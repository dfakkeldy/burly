// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// §2's mid-session ellipsis menu. These scenarios intentionally assert the
/// screen reached after each mutation, not merely that an action row was
/// tappable. `SessionActionsView` dismisses for ordinary actions, so every
/// post-tap value read waits for SwiftUI's next render rather than assuming a
/// synchronous accessibility-tree update.
final class SessionActionsUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAndRemoveEmptySetUpdateCounterAndRespectAvailability() throws {
        let app = launchLegDay(in: "routines")
        let setCounter = app.staticTexts["exercisePage.setCounter"]
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 3" })

        openActions(in: app)
        let addSet = app.buttons["sessionActions.addSet"]
        XCTAssertTrue(scrollUntilExists(app, addSet))
        XCTAssertTrue(addSet.isEnabled, "A current exercise should allow adding a set")
        addSet.tap()
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 4" })

        openActions(in: app)
        let removeEmptySet = app.buttons["sessionActions.removeEmptySet"]
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertTrue(removeEmptySet.isEnabled, "An unlogged fourth slot should be removable")
        removeEmptySet.tap()
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 3" })

        let logSet = app.buttons["logSetButton"]
        for expectedCounter in ["Set 2 of 3", "Set 3 of 3", "Set 3 of 3"] {
            XCTAssertTrue(logSet.waitForExistence(timeout: 5))
            logSet.tap()
            XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == expectedCounter })
        }

        openActions(in: app)
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertFalse(
            removeEmptySet.isEnabled,
            "Remove empty set must be disabled when canRemoveEmptySetOnCurrent is false"
        )
    }

    func testSkipReturnsToEmptySessionAndDisablesItemActionsWithoutCurrentItem() throws {
        let app = launchLegDay(in: "routines")

        openActions(in: app)
        let skip = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, skip))
        XCTAssertTrue(skip.isEnabled)
        skip.tap()

        let emptySessionAdd = app.buttons["emptySession.addExercise"]
        XCTAssertTrue(
            emptySessionAdd.waitForExistence(timeout: 5),
            "Skipping Leg Day's only exercise should render the empty-session state"
        )

        openActions(in: app)
        let addSet = app.buttons["sessionActions.addSet"]
        let removeEmptySet = app.buttons["sessionActions.removeEmptySet"]
        let skippedAction = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, addSet))
        XCTAssertTrue(scrollUntilExists(app, removeEmptySet))
        XCTAssertTrue(scrollUntilExists(app, skippedAction))
        XCTAssertFalse(addSet.isEnabled, "Add set must be disabled when currentItemID is nil")
        XCTAssertFalse(removeEmptySet.isEnabled, "Remove empty set must be disabled when currentItemID is nil")
        XCTAssertFalse(skippedAction.isEnabled, "Skip must be disabled when currentItemID is nil")
    }

    func testSkippingMiddleExerciseAdvancesAndKeepsRenderedOrdinalsDense() throws {
        let app = launchLegDay(in: "routines")
        let exerciseName = app.staticTexts["exercisePage.name"]

        addExercise(named: "Barbell Bench Press", in: app)
        addExercise(named: "Pull-Up", in: app)
        XCTAssertTrue(waitFor { exerciseName.exists && exerciseName.label == "Pull-Up" })

        swipeDownToPreviousPage(in: app)
        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Barbell Bench Press" },
            "Expected the middle page before skipping it"
        )

        openActions(in: app)
        let skip = app.buttons["sessionActions.skipExercise"]
        XCTAssertTrue(scrollUntilExists(app, skip))
        skip.tap()

        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Pull-Up" },
            "Skipping the middle exercise must advance to the next visible exercise, not restart the workout"
        )
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 2 of 2" },
            "After skipping the middle of three, the final visible page must be Exercise 2 of 2, never Exercise 3 of 2"
        )
    }

    func testMoveUpChangesTheRenderedPagerOrder() throws {
        let app = launchLegDay(in: "routines")
        let exerciseName = app.staticTexts["exercisePage.name"]

        openActions(in: app)
        let addExercise = app.buttons["sessionActions.addExercise"]
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()

        selectPickerExercise(named: "Barbell Bench Press", in: app)
        XCTAssertTrue(waitFor { exerciseName.exists && exerciseName.label == "Barbell Bench Press" })
        XCTAssertTrue(
            waitFor { (exerciseName.value as? String) == "Exercise 2 of 2" },
            "The added exercise must initially render after Back Squat"
        )

        openActions(in: app)
        let moveUp = app.buttons["sessionActions.moveUp"]
        XCTAssertTrue(scrollUntilExists(app, moveUp))
        XCTAssertTrue(moveUp.isEnabled)
        moveUp.tap()

        XCTAssertTrue(
            waitFor { exerciseName.exists && (exerciseName.value as? String) == "Exercise 1 of 2" },
            "Move up must change the rendered pager ordinal from second to first, proving the order changed"
        )
        XCTAssertTrue(waitFor { exerciseName.label == "Barbell Bench Press" })

        openActions(in: app)
        let moveDown = app.buttons["sessionActions.moveDown"]
        XCTAssertTrue(scrollUntilExists(app, moveDown))
        XCTAssertTrue(moveDown.isEnabled)
        moveDown.tap()
        XCTAssertTrue(
            waitFor { exerciseName.exists && (exerciseName.value as? String) == "Exercise 2 of 2" },
            "Move down must return the rendered exercise to the second pager position"
        )
    }

    func testAddExercisePickerPrioritizesRecentExerciseAndPlaceholderRoutesToNewPage() throws {
        let app = launchLegDay(in: "routines")
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
            "The most recently performed exercise must precede alphabetically earlier curated rows"
        )

        let placeholder = app.buttons["exercisePicker.addPlaceholder"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        placeholder.tap()
        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Custom exercise" },
            "Custom (name later) should create and route to the new placeholder item"
        )
    }

    // MARK: - Helpers

    private func launchLegDay(in scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = scenario
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

    /// Full-screen watch swipes jump from rows 1-4 to rows 6-9, so a lazy
    /// row at position 5 is never realized. Move roughly one row per attempt
    /// so every action passes through the accessibility fold.
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

    /// `XCUIApplication.swipeDown()` is too brief to page this watch
    /// `PUICPageViewController`-backed vertical pager. Use the same
    /// press-and-drag synthesis that reliably drives this app's scrolling.
    private func swipeDownToPreviousPage(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
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
