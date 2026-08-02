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
    private static let faultKey = "BURLY_WATCH_UI_TEST_FAULT"
    private static let storeTokenKey = "BURLY_WATCH_UI_TEST_STORE_TOKEN"

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

    // MARK: - Finding 6.1: SessionConflictView's own defensive path

    /// m2-06 review finding 6.1: the shell-level Resume gate makes
    /// `SessionConflictView` unreachable in *ordinary* use, but
    /// `SessionEntryView.start()`'s own defensive `resumableActiveSession()`
    /// pre-check still exists for the race the gate cannot fully close --
    /// a session becoming active between the shell's own check (which found
    /// nothing and rendered the routine list) and this view's independent
    /// re-check a moment later. `WatchDemoSeed`'s
    /// `injectActiveSessionOnSecondResumableCheck` fault makes that race
    /// deterministic: it injects a real active Push/Pull session exactly on
    /// the SECOND `resumableActiveSession()` call in the process (the
    /// shell's own first check already ran and found nothing, or this test
    /// would never reach the routine list to tap Leg Day in the first
    /// place).
    func testLateActiveSessionRaceReachesSessionConflictViewAndDiscardResolvesIt() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "injectActiveSessionOnLateResumableCheck"
        app.launch()

        // The shell's own gate check(s) found nothing at launch -- the
        // routine list renders normally.
        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        // Explicit margin past `lateSessionInjectionDelay` (1.5 s) --
        // guarantees the tap below lands after the fault's injection
        // window regardless of how quickly this simulator happened to
        // render, rather than depending on `waitForExistence` having
        // incidentally taken long enough on its own.
        Thread.sleep(forTimeInterval: 2)
        legDayRow.tap()

        // SessionEntryView's own defensive pre-check is where the fault's
        // now-injected active session gets caught.
        let conflictHeading = app.staticTexts["sessionConflict.heading"]
        XCTAssertTrue(
            conflictHeading.waitForExistence(timeout: 10),
            "Expected the late-active-session race to still be caught by SessionEntryView's own defensive check"
        )
        XCTAssertFalse(
            app.staticTexts["exercisePage.name"].exists,
            "No unsaved logging screen must ever appear while a session is already active"
        )

        attachScreenshot(from: app, name: "BurlyWatch-sessionConflictView-race-discard")

        let discardButton = app.buttons["sessionConflict.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()
        let confirmDiscard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected the originally-requested Start to proceed once SessionConflictView's Discard resolved the race"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    /// Same race, resolved via Finish instead of Discard.
    func testLateActiveSessionRaceReachesSessionConflictViewAndFinishResolvesIt() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "injectActiveSessionOnLateResumableCheck"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        legDayRow.tap()

        let conflictHeading = app.staticTexts["sessionConflict.heading"]
        XCTAssertTrue(conflictHeading.waitForExistence(timeout: 10))

        attachScreenshot(from: app, name: "BurlyWatch-sessionConflictView-race-finish")

        let finishButton = app.buttons["sessionConflict.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(
            exerciseName.waitForExistence(timeout: 10),
            "Expected the originally-requested Start to proceed once SessionConflictView's Finish resolved the race"
        )
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    // MARK: - Finding 4.2: activeConflict must not resurrect a resolved fixture

    /// m2-06 review finding 4.2: on an on-disk store, resolving the seeded
    /// `.activeConflict` fixture and then killing/relaunching the app with
    /// the identical scenario+token must NOT recreate a fresh conflict --
    /// a real store never resurrects a workout the lifter already
    /// discarded just because a relaunch's launch environment still names
    /// the same fixture scenario.
    func testActiveConflictDoesNotReseedAfterDiscardOnRelaunch() throws {
        let token = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launchEnvironment[Self.storeTokenKey] = token
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(resumeHeading.waitForExistence(timeout: 15))
        let notNowButton = app.buttons["resumeSession.notNowButton"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 5))
        notNowButton.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 10))
        let discardButton = app.buttons["sessionSummary.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()
        let confirmStepOne = app.buttons["discardConfirm.stepOneButton"]
        XCTAssertTrue(confirmStepOne.waitForExistence(timeout: 5))
        confirmStepOne.tap()
        let confirmStepTwo = app.buttons["discardConfirm.stepTwoButton"]
        XCTAssertTrue(confirmStepTwo.waitForExistence(timeout: 5))
        confirmStepTwo.tap()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 10), "Expected the routine list once the seeded conflict was discarded")

        // Kill and relaunch with the SAME scenario + store token -- a real
        // relaunch, reopening the same on-disk store.
        app.terminate()
        app.launch()

        // The resolved fixture must not come back: the routine list should
        // render directly, never the Resume gate again.
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 20),
            "Expected the routine list on relaunch, not a resurrected conflict"
        )
        XCTAssertFalse(
            app.staticTexts["resumeSession.heading"].exists,
            "A resolved fixture must never be recreated just because the relaunch's environment still names the same scenario"
        )
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
