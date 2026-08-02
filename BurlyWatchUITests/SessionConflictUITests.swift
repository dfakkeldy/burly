// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m2-03 review finding 1 (blocker): a second `Start` while a session is
/// already `.active` must never reach an unsaved logging screen. The store
/// correctly refuses the second `saveActiveSession`
/// (`.activeSessionAlreadyInFlight`), and the pre-fix code let a broken
/// logging screen run anyway with the refusal written into an unused
/// `errorMessage`.
///
/// `WatchDemoSeed.Scenario.activeConflict` seeds the same "Leg Day" /
/// "Push/Pull" routines as `.routines`, but leaves Push/Pull `.active` and
/// in flight -- exactly what a killed/backgrounded-mid-workout watch would
/// leave behind. Both tests here start Leg Day on top of that and assert
/// `SessionConflictView`'s finish-or-discard choice appears instead of an
/// unsaved `exercisePage.name`, and that resolving it lets the originally-
/// requested Start proceed automatically.
final class SessionConflictUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSecondStartWhileSessionActiveOffersDiscard() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let conflictHeading = app.staticTexts["sessionConflict.heading"]
        XCTAssertTrue(
            conflictHeading.waitForExistence(timeout: 10),
            "Expected a second Start to be blocked by the finish-or-discard conflict, never an unsaved logging screen"
        )
        XCTAssertFalse(
            app.staticTexts["exercisePage.name"].exists,
            "No unsaved logging screen must ever appear while a session is already active"
        )

        attachScreenshot(from: app, name: "BurlyWatch-sessionConflict-discard")

        let discardButton = app.buttons["sessionConflict.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()

        let confirmDiscard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.tap()

        // Discarding the conflicting session resolves it -- the originally
        // requested Start (Leg Day) proceeds without a second tap.
        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected the originally-requested Start to proceed once the conflict was discarded"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    func testSecondStartWhileSessionActiveOffersFinish() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let conflictHeading = app.staticTexts["sessionConflict.heading"]
        XCTAssertTrue(conflictHeading.waitForExistence(timeout: 10))

        attachScreenshot(from: app, name: "BurlyWatch-sessionConflict-finish")

        let finishButton = app.buttons["sessionConflict.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected the originally-requested Start to proceed once the conflict was finished"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
