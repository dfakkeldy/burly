// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Spec §2 acceptance #3 and #5 -- the real logging screen (m2-03),
/// driven through the same `WatchDemoSeed` "routines" scenario
/// BurlyWatchUITests.swift uses for the routine list, extended (see
/// WatchDemoSeed.swift) with a seeded `ExerciseLastPerformance` digest for
/// Back Squat and no digest at all for Bench Press / Pull-Up.
///
/// Selection goes through stable `accessibilityIdentifier`s throughout,
/// same house rule as BurlyWatchUITests.swift; numeric assertions
/// (prefill, ghost text, totals) are checked against literal values
/// computed by hand from the seed's kg figures, since this target cannot
/// import BurlyCore to compute them (it runs out-of-process against the
/// compiled app).
final class LoggingScreenUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// §2 acceptance #3: full flow -- start routine -> log 3 sets (prefill
    /// asserted against seeded last-performance, set index by set index)
    /// -> swap exercise -> finish -> summary shows correct totals; the
    /// weight control's accessibility value exposes locked/armed.
    ///
    /// Also exercises the seeded half of acceptance #5 (ghost row per set
    /// index); the absent-digest half is `testAbsentDigestRendersEmptyGhosts`.
    func testFullSessionFlowLogSwapFinishShowsCorrectTotals() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15), "Expected the seeded 'Leg Day' routine")
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10), "Expected the logging screen to open")
        XCTAssertEqual(exerciseName.label, "Back Squat")

        let ghost = app.staticTexts["exercisePage.ghost"]
        let weightControl = anyElement(app, identifier: "weightControl")
        let repsControl = anyElement(app, identifier: "repsControl")
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))

        // Set 1 of 3 -- prefill from the seeded digest's index 0 (100 kg × 8).
        assertPrefill(ghost: ghost, weightControl: weightControl, repsControl: repsControl, weightText: "220.5 lb", reps: "8")

        // §2 acceptance #3: the weight control's accessibility value
        // exposes locked/armed state.
        XCTAssertTrue((weightControl.value as? String)?.contains("locked") == true, "Expected the weight control to start locked")
        weightControl.press(forDuration: 0.6)
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("armed") == true },
            "Expected the long press to arm the weight control"
        )

        logButton.tap()
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("locked") == true },
            "Expected logging to auto-lock the weight control even though it was armed"
        )

        // Set 2 of 3 -- digest index 1 (102.5 kg × 7).
        assertPrefill(ghost: ghost, weightControl: weightControl, repsControl: repsControl, weightText: "226.0 lb", reps: "7")
        logButton.tap()

        // Set 3 of 3 -- digest index 2 (105 kg × 6).
        assertPrefill(ghost: ghost, weightControl: weightControl, repsControl: repsControl, weightText: "231.5 lb", reps: "6")
        logButton.tap()

        attachScreenshot(from: app, name: "BurlyWatch-loggingScreen-threeSetsLogged")

        // §2 ellipsis "swap exercise."
        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()

        let swapAction = app.buttons["sessionActions.swapExercise"]
        XCTAssertTrue(swapAction.waitForExistence(timeout: 5))
        swapAction.tap()

        let firstCatalogRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'exercisePicker.row.'")
        ).element(boundBy: 0)
        XCTAssertTrue(firstCatalogRow.waitForExistence(timeout: 5), "Expected at least one catalog exercise in the swap picker")
        let swappedToName = firstCatalogRow.label
        firstCatalogRow.tap()

        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == swappedToName },
            "Expected the logging screen to route to the swapped-in exercise"
        )

        // §2 Finish: "End workout" -> summary -> Finish.
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(endWorkout.waitForExistence(timeout: 5))
        endWorkout.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 5))
        XCTAssertEqual(summaryHeading.label, "End workout?")

        // Deterministic regardless of the real wall-clock time the test
        // took: 3 sets logged (the swapped-in item has none), and
        // volume = 100×8 + 102.5×7 + 105×6 kg -> ≈4734 lb.
        let setsRow = anyElement(app, identifier: "sessionSummary.sets")
        XCTAssertTrue(setsRow.label.contains("3"), "Expected 3 total sets, got '\(setsRow.label)'")
        let volumeRow = anyElement(app, identifier: "sessionSummary.volume")
        XCTAssertTrue(volumeRow.label.contains("4734"), "Expected ~4734 lb total volume, got '\(volumeRow.label)'")

        attachScreenshot(from: app, name: "BurlyWatch-endWorkoutSummary")

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        XCTAssertTrue(
            waitFor { summaryHeading.exists && summaryHeading.label == "Workout saved" },
            "Expected Finish to commit and show the saved acknowledgement"
        )

        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected Done to return to the routine list"
        )
    }

    /// §2 acceptance #5, absent-digest half: Bench Press and Pull-Up were
    /// seeded with no `ExerciseLastPerformance` at all -- the ghost row
    /// must render an empty state on both, with no crash and no numbers
    /// carried over from one page to the next.
    func testAbsentDigestRendersEmptyGhostsAcrossPages() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let pushPullRow = app.staticTexts["routineRow.Push/Pull.name"]
        XCTAssertTrue(pushPullRow.waitForExistence(timeout: 15))
        pushPullRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        let ghost = app.staticTexts["exercisePage.ghost"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Barbell Bench Press")
        XCTAssertTrue(waitFor { ghost.exists && ghost.label == "No previous data" })

        let weightControl = anyElement(app, identifier: "weightControl")
        XCTAssertTrue((weightControl.value as? String)?.contains("0.0 lb") == true, "Expected bodyweight fallback with no digest")

        attachScreenshot(from: app, name: "BurlyWatch-ghostRow-absentDigest-benchPress")

        app.swipeUp()

        XCTAssertTrue(
            waitFor { exerciseName.exists && exerciseName.label == "Pull-Up" },
            "Expected paging to reach Pull-Up"
        )
        XCTAssertTrue(
            waitFor { ghost.exists && ghost.label == "No previous data" },
            "Expected Pull-Up's ghost row to be empty too, not stale text from Bench Press"
        )

        attachScreenshot(from: app, name: "BurlyWatch-ghostRow-absentDigest-pullUp")
    }

    // MARK: - Helpers

    private func assertPrefill(
        ghost: XCUIElement,
        weightControl: XCUIElement,
        repsControl: XCUIElement,
        weightText: String,
        reps: String
    ) {
        XCTAssertTrue(waitFor { ghost.exists && ghost.label == "Last: \(weightText) × \(reps)" },
                       "Expected ghost row 'Last: \(weightText) × \(reps)', got '\(ghost.label)'")
        XCTAssertTrue(waitFor { (weightControl.value as? String)?.contains(weightText) == true },
                       "Expected weight prefill \(weightText), got \(String(describing: weightControl.value))")
        XCTAssertTrue(waitFor { (repsControl.value as? String) == reps },
                       "Expected reps prefill \(reps), got \(String(describing: repsControl.value))")
    }

    /// Polls `condition` for up to `timeout` seconds -- covers the small
    /// window between an action firing and `@Observable` propagating to
    /// the accessibility tree, without a fixed sleep.
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Same rationale as BurlyWatchUITests.swift's helper of the same name:
    /// looks a stable identifier up regardless of the accessibility element
    /// type SwiftUI/watchOS happens to expose it as.
    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
