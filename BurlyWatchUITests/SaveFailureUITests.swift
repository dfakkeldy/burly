// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m2-03 review findings 6-9: "a lifter mid-workout must never be lied to
/// about whether their sets are saved." A real storage failure essentially
/// never happens against the simulator's SwiftData store, so these tests
/// drive `WatchDemoSeed`'s `FaultInjectingStore` -- a decorator that wraps
/// the real store and deterministically fails one named method for a
/// chosen number of calls -- via the `BURLY_WATCH_UI_TEST_FAULT*` launch-
/// environment keys. Every scenario below still seeds the same "Leg Day" /
/// "Push/Pull" routines `.routines` does; only the fault axis differs.
final class SaveFailureUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"
    private static let faultKey = "BURLY_WATCH_UI_TEST_FAULT"
    private static let faultSuccessesKey = "BURLY_WATCH_UI_TEST_FAULT_SUCCESSES"
    private static let faultCountKey = "BURLY_WATCH_UI_TEST_FAULT_COUNT"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Finding 7: an ordinary logged-set save failure must block the
    /// screen -- never a success haptic/advance on an unsaved set -- and
    /// Retry must actually recover.
    func testLogSetSaveFailureBlocksScreenAndRetrySucceeds() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "saveActiveSession"
        app.launchEnvironment[Self.faultSuccessesKey] = "1" // let Start's own save through
        app.launchEnvironment[Self.faultCountKey] = "1" // fail exactly the first logged set's save
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        XCTAssertTrue(app.staticTexts["exercisePage.name"].waitForExistence(timeout: 10))
        let setCounter = app.staticTexts["exercisePage.setCounter"]
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 1 of 3" })

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))
        logButton.tap()

        let saveFailureHeading = app.staticTexts["saveFailure.heading"]
        XCTAssertTrue(
            saveFailureHeading.waitForExistence(timeout: 5),
            "Expected a blocking save-failure state -- never a success haptic/advance on an unsaved set"
        )

        attachScreenshot(from: app, name: "BurlyWatch-saveFailure-logSet")

        let retryButton = app.buttons["saveFailure.retryButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.tap()

        // Retry succeeds (the fault only fires once): back on the logging
        // screen, genuinely advanced to set 2 -- exactly one set logged,
        // not zero (masked failure) and not two (a double-apply from a
        // botched rollback).
        XCTAssertTrue(
            waitFor { setCounter.exists && setCounter.label == "Set 2 of 3" },
            "Expected the retried log to succeed and advance to exactly set 2"
        )
        XCTAssertFalse(app.staticTexts["saveFailure.heading"].exists)
    }

    /// Finding 8: placeholder exercise creation must not commit the engine
    /// mutation unless catalog persistence succeeds.
    func testPlaceholderExerciseCreateFailureBlocksAndRetrySucceeds() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "createExercise"
        app.launchEnvironment[Self.faultSuccessesKey] = "0" // the very first createExercise call is the placeholder attempt
        app.launchEnvironment[Self.faultCountKey] = "1"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()
        XCTAssertTrue(app.staticTexts["exercisePage.name"].waitForExistence(timeout: 10))

        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()

        // "Add exercise" is row 5 of 9 in SessionActionsView's lazily-rendered
        // List -- past the initial-scroll-position fold on the 46 mm sim,
        // same reason "Discard workout" (row 9) and "End workout" (row 8)
        // need this elsewhere in this file / LoggingScreenUITests.swift.
        let addExercise = app.buttons["sessionActions.addExercise"]
        XCTAssertTrue(scrollUntilExists(app, addExercise), "Expected to be able to scroll to 'Add exercise'")
        addExercise.tap()

        let addPlaceholder = app.buttons["exercisePicker.addPlaceholder"]
        XCTAssertTrue(addPlaceholder.waitForExistence(timeout: 5))
        addPlaceholder.tap()

        let saveFailureHeading = app.staticTexts["saveFailure.heading"]
        XCTAssertTrue(
            saveFailureHeading.waitForExistence(timeout: 5),
            "Expected placeholder creation to block on a catalog-persistence failure rather than leaving a dangling session reference"
        )

        attachScreenshot(from: app, name: "BurlyWatch-saveFailure-placeholderExercise")

        let retryButton = app.buttons["saveFailure.retryButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.tap()

        // Retry succeeds and routes to the freshly-created placeholder's
        // own page.
        XCTAssertTrue(
            waitFor { !saveFailureHeading.exists && app.staticTexts["exercisePage.name"].exists },
            "Expected the retried placeholder creation to succeed and land on the new item"
        )
    }

    /// Finding 9: Discard must set `didDiscard` only after a successful
    /// deletion -- reachable directly from the ellipsis menu, not only
    /// from the End-workout summary, so its failure state must be visible
    /// from there too.
    func testDiscardFailureBlocksAndRetrySucceeds() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "deleteSession"
        app.launchEnvironment[Self.faultSuccessesKey] = "0"
        app.launchEnvironment[Self.faultCountKey] = "1"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()
        XCTAssertTrue(app.staticTexts["exercisePage.name"].waitForExistence(timeout: 10))

        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()

        let discardAction = app.buttons["sessionActions.discardWorkout"]
        XCTAssertTrue(scrollUntilExists(app, discardAction), "Expected to be able to scroll to 'Discard workout'")
        discardAction.tap()

        let confirmStepOne = app.buttons["Discard"].firstMatch
        XCTAssertTrue(confirmStepOne.waitForExistence(timeout: 5))
        confirmStepOne.tap()

        let confirmStepTwo = app.buttons["Discard permanently"].firstMatch
        XCTAssertTrue(confirmStepTwo.waitForExistence(timeout: 5))
        confirmStepTwo.tap()

        let saveFailureHeading = app.staticTexts["saveFailure.heading"]
        XCTAssertTrue(
            saveFailureHeading.waitForExistence(timeout: 5),
            "Expected a retryable error, not a silent dismissal, when deleteSession fails"
        )

        attachScreenshot(from: app, name: "BurlyWatch-saveFailure-discard")

        let retryButton = app.buttons["saveFailure.retryButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.tap()

        // Retry succeeds; the screen actually dismisses back to the
        // routine list -- proof `didDiscard` only ever followed a real
        // deletion.
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the retried discard to succeed and return to the routine list"
        )
    }

    /// Finding 6: a Finish whose `engine.finish()` succeeded but whose
    /// follow-up save failed must be recoverable without re-invoking
    /// `finish()` (which would now throw `.sessionNotActive`) -- Keep
    /// going/Discard must be disabled once Finish has been attempted, and
    /// Retry must actually recover.
    func testFinishSaveFailureIsRecoverableWithoutReFinishing() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "saveActiveSession"
        app.launchEnvironment[Self.faultSuccessesKey] = "1" // Start's own save
        app.launchEnvironment[Self.faultCountKey] = "1" // fail the Finish save
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()
        XCTAssertTrue(app.staticTexts["exercisePage.name"].waitForExistence(timeout: 10))

        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
        endWorkout.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 5))

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        let saveError = app.staticTexts["sessionSummary.saveError"]
        XCTAssertTrue(
            saveError.waitForExistence(timeout: 5),
            "Expected a recoverable error, not a silently stuck screen, when Finish's save fails"
        )
        XCTAssertFalse(
            app.buttons["sessionSummary.keepGoingButton"].isEnabled,
            "Keep going must be disabled once Finish has been attempted -- the in-memory session is already .logged"
        )
        XCTAssertFalse(
            app.buttons["sessionSummary.discardButton"].isEnabled,
            "Discard must be disabled once Finish has been attempted"
        )

        attachScreenshot(from: app, name: "BurlyWatch-saveFailure-finish")

        let retryButton = app.buttons["sessionSummary.retryFinishButton"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5))
        retryButton.tap()

        XCTAssertTrue(
            waitFor { summaryHeading.exists && summaryHeading.label == "Workout saved" },
            "Expected the retried Finish save to succeed without calling engine.finish() again"
        )
    }

    // MARK: - Helpers

    private func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement, maxAttempts: Int = 8) -> Bool {
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

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
