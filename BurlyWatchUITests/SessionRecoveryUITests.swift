// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Cross-engine review of m2-06 (round 1): the crash/resume happy path was
/// correct, but two "second-order recovery" gaps were NOT-SAFE --
///
/// - Finding 2.1: an unreadable active-session journal wedged the whole
///   app behind a Retry that could never succeed.
/// - Finding 3.1: `.sessionNoLongerInFlight` (the store legitimately
///   moving a session out of `.active` while this view was still attached
///   to it) was treated as an ordinary retryable save failure, which can
///   never resolve and left Finish's `isFinishing` stuck `true` forever.
///
/// Round 2 (finding 1) found the round-1 fix incomplete: `WatchHomeViewModel
/// .load()`'s shell-level gate caught `.unreadableActiveSessionJournal`
/// distinctly, but `SessionEntryView` makes the same two calls
/// independently and both still folded the error into the generic
/// `.failed` state (a dead-end `StoreUnavailableView`, no Retry, no
/// recovery) -- the defensive new-session preflight
/// (`resumableActiveSession()`) and `.resume`'s own fetch
/// (`activeSession(id:)`). Both now route to the same `UnreadableSessionView`
/// Discard recovery the shell uses.
///
/// All of this drives `WatchDemoSeed`'s `FaultInjectingStore` faults --
/// see that file's doc for why a UI test needs a deliberate seam here
/// rather than trying to induce a real corrupt payload or a real
/// concurrent writer from black-box taps.
final class SessionRecoveryUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"
    private static let faultKey = "BURLY_WATCH_UI_TEST_FAULT"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Finding 2.1: a persistently unreadable active journal must offer a
    /// targeted, self-clearing recovery -- never a Retry-only wedge.
    /// `.activeConflict` leaves Push/Pull genuinely active; the fault
    /// makes every read of it report the real decode-failure shape
    /// instead.
    func testUnreadableActiveJournalOffersDiscardAndAppIsUsableAfterward() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launchEnvironment[Self.faultKey] = "resumableActiveSessionUnreadable"
        app.launch()

        let heading = app.staticTexts["unreadableSession.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 15),
            "Expected the targeted unreadable-session recovery, not the Resume gate or a generic Retry-only failure"
        )
        XCTAssertFalse(app.staticTexts["resumeSession.heading"].exists)
        XCTAssertFalse(app.staticTexts["storeUnavailableView.heading"].exists)

        attachScreenshot(from: app, name: "BurlyWatch-unreadableSession-offered")

        let discardButton = app.buttons["unreadableSession.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()

        // The app is usable afterward: the routine list renders (the
        // unreadable session is gone, and it was the only thing blocking
        // it), and a fresh Start proceeds normally -- proof this isn't a
        // recovery screen that itself dead-ends.
        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the routine list once the unreadable session was discarded"
        )
        XCTAssertFalse(app.staticTexts["unreadableSession.heading"].exists)
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    /// Round 2, finding 1(a): the defensive new-session preflight
    /// (`SessionEntryView.start()`'s own `resumableActiveSession()` check)
    /// must catch `.unreadableActiveSessionJournal` distinctly too, not
    /// fold it into `StoreUnavailableView`. Nothing is active at launch --
    /// the shell's own gate sees nothing, the routine list renders, and
    /// the fault injects a session that is both active AND unreadable
    /// strictly at the moment `SessionEntryView` makes its own check
    /// (identified by caller, not timing -- see `Fault
    /// .injectUnreadableActiveSessionOnDefensivePreflight`'s doc).
    func testUnreadableJournalAtDefensivePreflightOffersDiscardAndAppIsUsableAfterward() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.faultKey] = "injectUnreadableActiveSessionOnDefensivePreflight"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15), "Expected the routine list -- nothing is active at launch")
        legDayRow.tap()

        let heading = app.staticTexts["unreadableSession.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 10),
            "Expected the targeted unreadable-session recovery at the defensive preflight, not a dead-end StoreUnavailableView"
        )
        XCTAssertFalse(app.staticTexts["storeUnavailableView.heading"].exists)
        XCTAssertFalse(
            app.staticTexts["exercisePage.name"].exists,
            "No unsaved logging screen must ever appear while a (corrupt) session is already active"
        )

        attachScreenshot(from: app, name: "BurlyWatch-unreadableSession-defensivePreflight")

        let discardButton = app.buttons["unreadableSession.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()

        // The app is usable afterward: back at the routine list, and the
        // originally-requested Start proceeds normally.
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the routine list once the unreadable session was discarded"
        )
        legDayRow.tap()
        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    /// Round 2, finding 1(b): `.resume`'s own `activeSession(id:)` fetch
    /// must catch `.unreadableActiveSessionJournal` distinctly too. The
    /// shell's own Resume preview is unaffected (only `activeSession(id:)`
    /// is intercepted, not `resumableActiveSession()`), so Resume is
    /// offered normally; the journal only turns out to be unreadable once
    /// `.resume` tries to actually fetch it.
    func testUnreadableJournalAtResumeFetchOffersDiscardAndAppIsUsableAfterward() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeConflict"
        app.launchEnvironment[Self.faultKey] = "resumeFetchUnreadable"
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(resumeHeading.waitForExistence(timeout: 15), "Expected Resume to be offered -- the shell's own preview is unaffected")
        let resumeButton = app.buttons["resumeSession.resumeButton"]
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
        resumeButton.tap()

        let heading = app.staticTexts["unreadableSession.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 10),
            "Expected the targeted unreadable-session recovery at the resume fetch, not a dead-end StoreUnavailableView"
        )
        XCTAssertFalse(app.staticTexts["storeUnavailableView.heading"].exists)

        attachScreenshot(from: app, name: "BurlyWatch-unreadableSession-resumeFetch")

        let discardButton = app.buttons["unreadableSession.discardButton"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 5))
        discardButton.tap()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 10),
            "Expected the routine list once the unreadable session was discarded"
        )
        legDayRow.tap()
        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Back Squat")
    }

    /// Finding 3.1, log path: a save that discovers the store already
    /// moved the session out of `.active` must resolve to a terminal
    /// state, never install a retry that resubmits the same stale active
    /// session forever.
    ///
    /// Uses `.activeLegDay`, not `.activeConflict` -- Leg Day's own item
    /// (Back Squat) has a seeded digest, so Resume prefills real reps
    /// immediately and Log set is enabled without needing to manually
    /// raise reps from "unset" first (see this file's own doc on why that
    /// isn't reliably possible from XCUITest here).
    func testSessionInvalidatedDuringLogRoutesToTerminalStateNotRetryLoop() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeLegDay"
        app.launchEnvironment[Self.faultKey] = "forceSessionOutOfFlightBeforeNextSave"
        app.launch()

        // The Resume gate offers the pre-seeded Leg Day session.
        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(resumeHeading.waitForExistence(timeout: 15))
        let resumeButton = app.buttons["resumeSession.resumeButton"]
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
        resumeButton.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))
        XCTAssertEqual(exerciseName.label, "Back Squat")

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(waitFor { logButton.exists && logButton.isEnabled }, "Expected the seeded digest to prefill real reps so Log set is enabled")
        // The fault fires on this exact saveActiveSession call: it forces
        // the reattached session out of .active via a real store edit
        // first, so the log's own save then hits the real
        // .sessionNoLongerInFlight.
        logButton.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(
            waitFor { summaryHeading.exists && summaryHeading.label == "Workout saved" },
            "Expected a terminal 'Workout saved' routing, not a stuck blocking retry state"
        )
        XCTAssertFalse(
            app.staticTexts["saveFailure.heading"].exists,
            "Must never be left on the ordinary blocking-retry screen for a save that can never succeed"
        )

        attachScreenshot(from: app, name: "BurlyWatch-sessionInvalidated-logPath")

        // Not a dead end: Done returns to a normal, working shell.
        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(app.staticTexts["routineRow.Leg Day.name"].waitForExistence(timeout: 10))
    }

    /// Finding 3.1, Finish path: the specific gap the review named by
    /// example -- `isFinishing` must clear, not strand Keep going/Discard
    /// disabled forever behind a Retry that can never succeed.
    func testSessionInvalidatedDuringFinishClearsIsFinishingAndRoutesToTerminalState() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "activeLegDay"
        app.launchEnvironment[Self.faultKey] = "forceSessionOutOfFlightBeforeNextSave"
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(resumeHeading.waitForExistence(timeout: 15))
        let resumeButton = app.buttons["resumeSession.resumeButton"]
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
        resumeButton.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))

        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
        endWorkout.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 5))
        XCTAssertEqual(summaryHeading.label, "End workout?")

        let finishButton = app.buttons["sessionSummary.finishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        // The fault fires on persistFinish()'s saveActiveSession call.
        finishButton.tap()

        XCTAssertTrue(
            waitFor { summaryHeading.exists && summaryHeading.label == "Workout saved" },
            "Expected Finish to route to the terminal 'Workout saved' state rather than sticking on the preview with isFinishing stuck true"
        )
        XCTAssertFalse(app.buttons["sessionSummary.finishButton"].exists)
        XCTAssertFalse(app.buttons["sessionSummary.keepGoingButton"].exists)
        XCTAssertFalse(app.buttons["sessionSummary.discardButton"].exists)
        XCTAssertFalse(app.staticTexts["sessionSummary.saveError"].exists)

        attachScreenshot(from: app, name: "BurlyWatch-sessionInvalidated-finishPath")

        let doneButton = app.buttons["sessionSummary.doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
        XCTAssertTrue(app.staticTexts["routineRow.Leg Day.name"].waitForExistence(timeout: 10))
    }

    // MARK: - Helpers

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
