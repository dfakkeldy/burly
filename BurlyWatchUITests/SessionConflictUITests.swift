// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// m2-03 review finding 1 (blocker): a session already `.active` must never
/// leave the lifter looking at an unsaved logging screen or a routine list
/// that pretends nothing is running. m2-03's original fix caught this only
/// at the moment of a *second Start*: `SessionEntryView`'s own
/// `resumableActiveSession()` pre-check routed a hit to
/// `SessionConflictView`'s finish-or-discard choice.
///
/// m2-06 moved the check one level up: `WatchHomeViewModel.load()` now
/// gates the *whole shell* on the same lookup (spec §2 "Relaunch with an
/// `.active` session in store → Resume screen"), so `ResumeSessionView` --
/// not the routine list -- is what actually appears on launch while
/// `WatchDemoSeed.Scenario.activeConflict` has Push/Pull sitting `.active`.
/// `SessionEntryView`'s own pre-check is kept as defense in depth (see its
/// file doc) but is no longer reachable through the routine list in
/// ordinary use, so these two tests now exercise the gate that actually
/// fires: launching with a session already in flight offers Resume, not the
/// routine list; declining it (§2: "Declining resume = normal end-workout
/// summary path") and resolving it there via Discard or Finish is what
/// unblocks the routine list -- proving Leg Day's Start proceeds normally
/// afterward, same end guarantee the original tests pinned.
final class SessionConflictUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testActiveSessionAtLaunchOffersResumeGateDiscardingReturnsToRoutineList() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(
            resumeHeading.waitForExistence(timeout: 15),
            "Expected the Resume gate on launch with an already-active session, never the routine list underneath it"
        )
        XCTAssertFalse(
            app.staticTexts["routineRow.Leg Day.name"].exists,
            "The routine list must not be reachable while a session is active"
        )
        XCTAssertFalse(
            app.staticTexts["exercisePage.name"].exists,
            "No unsaved logging screen must ever appear while a session is already active"
        )

        attachScreenshot(from: app, name: "BurlyWatch-resumeGate-conflict-discard")

        // Decline: §2's own text -- "normal end-workout summary path."
        let notNowButton = app.buttons["resumeSession.notNowButton"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 5))
        notNowButton.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 10))
        XCTAssertEqual(summaryHeading.label, "End workout?")

        let discardButton = app.buttons["sessionSummary.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()

        let confirmStepOne = app.buttons["discardConfirm.stepOneButton"]
        XCTAssertTrue(confirmStepOne.waitForExistence(timeout: 5))
        confirmStepOne.tap()
        let confirmStepTwo = app.buttons["discardConfirm.stepTwoButton"]
        XCTAssertTrue(confirmStepTwo.waitForExistence(timeout: 5))
        confirmStepTwo.tap()

        // Discarding the conflicting session resolves it: the routine list
        // reappears, and the originally-blocked Start on Leg Day proceeds.
        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the routine list once the conflicting session was discarded"
        )
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected Start to proceed normally once the conflict was resolved"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    func testActiveSessionAtLaunchOffersResumeGateFinishingReturnsToRoutineList() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(resumeHeading.waitForExistence(timeout: 15))

        attachScreenshot(from: app, name: "BurlyWatch-resumeGate-conflict-finish")

        let notNowButton = app.buttons["resumeSession.notNowButton"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 5))
        notNowButton.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 10))
        XCTAssertEqual(summaryHeading.label, "End workout?")

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        XCTAssertTrue(
            waitFor { summaryHeading.exists && summaryHeading.label == "Workout saved" },
            "Expected Finish to commit the conflicting session"
        )
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the routine list once the conflicting session was finished"
        )
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected Start to proceed normally once the conflict was resolved"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
