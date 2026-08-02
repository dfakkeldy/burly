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

        // §2 Finish: "End workout" -> summary -> Finish. The actions sheet
        // is a plain `List` (SessionActionsView.swift) -- watchOS renders
        // it lazily, so a row this far down the list ("End workout" is the
        // 8th of 9 rows) doesn't exist in the accessibility tree until it's
        // scrolled into view.
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
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
    ///
    /// Also m2-03 review finding 3: an honestly-empty prefill must never
    /// render as an invented bodyweight×8. This test previously asserted
    /// the *invented* fallback ("0.0 lb" weight, an implicit "8" reps) --
    /// it now asserts the honest placeholder and that Log set stays
    /// disabled until the lifter enters a real value.
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
        let repsControl = anyElement(app, identifier: "repsControl")
        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("not set") == true },
            "Expected an honest 'not set' placeholder, not an invented bodyweight value, with no digest"
        )
        XCTAssertTrue(
            waitFor { (repsControl.value as? String) == "not set" },
            "Expected an honest 'not set' placeholder, not an invented '8', with no digest"
        )
        XCTAssertFalse(logButton.isEnabled, "Expected Log set to be disabled with nothing entered yet -- there is nothing honest to log")

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
        XCTAssertTrue(
            waitFor { (repsControl.value as? String) == "not set" },
            "Expected Pull-Up's own reps to be freshly empty, not carried over from Bench Press"
        )

        attachScreenshot(from: app, name: "BurlyWatch-ghostRow-absentDigest-pullUp")
    }

    /// m2-03 review finding 4: skip/swap/add must emit the engine's
    /// `.pageAway` event, not just its haptic -- arming the weight control
    /// and then swapping the exercise must land on the new exercise's page
    /// already re-locked, never armed carried over from the exercise the
    /// lifter just left.
    func testSwapExerciseRelocksWeightControl() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10))

        let weightControl = anyElement(app, identifier: "weightControl")
        XCTAssertTrue(waitFor { (weightControl.value as? String)?.contains("locked") == true })
        weightControl.press(forDuration: 0.6)
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("armed") == true },
            "Expected the long press to arm the weight control"
        )

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
        firstCatalogRow.tap()

        XCTAssertTrue(waitFor { exerciseName.exists }, "Expected the swap to land on a new exercise page")
        XCTAssertTrue(
            waitFor { (weightControl.value as? String)?.contains("locked") == true },
            "Expected the swapped-in exercise to require a fresh arm, not carry the previous armed state"
        )
        XCTAssertFalse(
            (weightControl.value as? String)?.contains("armed") == true,
            "The weight control must not still read armed after a swap"
        )
    }

    /// m2-03 review finding 10: the summary's digest-scoped "beat last
    /// time" signal must never be labeled a real PR -- `SessionSummary`'s
    /// own doc explains why the watch cannot compute an all-time one. The
    /// full-session flow above never exceeds the seeded digest (it logs
    /// the digest's own numbers back, at best tying its max, never beating
    /// it), so the row never renders there; this test only pins the
    /// negative half -- the old, wrong "New PR" copy/identifier must never
    /// appear anywhere in a completed summary. Driving the true-positive
    /// path deterministically would require either simulating a Digital
    /// Crown weight increase (no reliable, calibrated way to do that from
    /// XCUITest without live simulator tuning this task had no way to
    /// perform) or a resumed pre-logged session (m2-06's Resume flow,
    /// explicitly out of scope) -- see the handoff for why this is a
    /// deliberately incomplete pin rather than a skipped one.
    func testSummaryNeverShowsInventedPRLabel() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        logButton.tap()

        let ellipsis = anyElement(app, identifier: "ellipsisMenu")
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5))
        ellipsis.tap()
        let endWorkout = app.buttons["sessionActions.endWorkout"]
        XCTAssertTrue(scrollUntilExists(app, endWorkout), "Expected to be able to scroll to 'End workout'")
        endWorkout.tap()

        let summaryHeading = app.staticTexts["sessionSummary.heading"]
        XCTAssertTrue(summaryHeading.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["sessionSummary.personalRecords"].exists,
            "The old 'New PR' identifier must no longer exist in the view"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'New PR'")).firstMatch.exists,
            "The summary must never claim a real all-time PR from digest-scoped data"
        )
    }

    /// m2-03 review finding 11: the rest timer's tap-to-skip target and
    /// ±15 s adjust buttons must each have an explicit minimum 44×44pt hit
    /// region. (Weight/reps micro-buttons get the same fix, but --
    /// deliberately collapsed into one VoiceOver element apiece via
    /// `.accessibilityElement(children: .ignore)`, the axiom-accessibility
    /// custom-adjustable-control pattern -- their individual child buttons
    /// aren't independently queryable here; see the fix's code comments
    /// for that half.)
    func testRestTimerControlsHaveMinimumHitRegions() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        logButton.tap()

        // Ground truth (live accessibility-tree dump, m2-03 review round 3):
        // `ExercisePageView`'s `ScrollView` wraps a plain `VStack`, not a
        // lazy container, so every child -- including the rest timer banner
        // -- is already present in the accessibility tree immediately after
        // logging a set, regardless of scroll position (`XCUIElement.exists`
        // does not require on-screen visibility). The banner WAS rendering
        // correctly all along; the real defect was `RestTimerBanner`'s own
        // container-level `.accessibilityIdentifier("restTimerBanner")`
        // clobbering its three children's individually-set identifiers (see
        // that file's fix). No scroll is needed here.
        let remaining = app.staticTexts["restTimer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected the rest timer to auto-start after logging a set")

        let decrease = anyElement(app, identifier: "restTimer.decreaseButton")
        let increase = anyElement(app, identifier: "restTimer.increaseButton")
        XCTAssertTrue(decrease.waitForExistence(timeout: 5))
        XCTAssertTrue(increase.waitForExistence(timeout: 5))

        for (name, element) in [("skip target", remaining), ("decrease button", decrease), ("increase button", increase)] {
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "Expected the \(name) to have at least a 44pt-wide hit region")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "Expected the \(name) to have at least a 44pt-tall hit region")
        }
    }

    /// §3 acceptance #2: logging starts the persisted wall-clock timer;
    /// the timeline renders a changing value, adjustment immediately moves
    /// it forward, and the confirm-free countdown tap clears it.
    func testRestTimerCountsDownAdjustsAndSkips() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        legDayRow.tap()

        let logButton = app.buttons["logSetButton"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        logButton.tap()

        let remaining = app.staticTexts["restTimer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected a rest countdown after logging a set")
        let initialSeconds = try restSeconds(from: remaining.value)

        // A timeline update must make progress without an arbitrary sleep.
        XCTAssertTrue(
            waitFor(timeout: 3) {
                guard let current = try? self.restSeconds(from: remaining.value) else { return false }
                return current < initialSeconds
            },
            "Expected the wall-clock countdown to decrease"
        )

        let increase = anyElement(app, identifier: "restTimer.increaseButton")
        XCTAssertTrue(increase.waitForExistence(timeout: 5))
        let beforeIncrease = try restSeconds(from: remaining.value)
        increase.tap()
        XCTAssertTrue(
            waitFor {
                guard let current = try? self.restSeconds(from: remaining.value) else { return false }
                return current > beforeIncrease
            },
            "Expected +15 seconds to update the countdown immediately"
        )

        remaining.tap()
        XCTAssertTrue(
            waitFor(timeout: 5) { !remaining.exists },
            "Expected tapping the countdown to skip and clear the rest timer"
        )
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

    /// Swipes up on the app's frontmost content until `element` exists (or
    /// gives up after `maxAttempts`) -- for a lazily-rendered `List` row
    /// that isn't in the accessibility tree at the current scroll position.
    private func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement, maxAttempts: Int = 8) -> Bool {
        for _ in 0..<maxAttempts {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
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

    private func restSeconds(from value: Any?) throws -> Int {
        guard let text = value as? String,
              let seconds = Int(text.split(separator: " ", maxSplits: 1).first ?? "") else {
            throw RestTimerLabelError.invalid(String(describing: value))
        }
        return seconds
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum RestTimerLabelError: Error {
    case invalid(String)
}
