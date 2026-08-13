// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Spec §2 acceptance #4 and §3 acceptance #3 (m2-06): a real process kill
/// and relaunch on the sim, proving the crash-journal + Resume flow end to
/// end -- not just against `BurlyPersistenceTests`' `reopened`-store
/// fixtures, but through the exact watch UI a lifter uses (Start, tap Log
/// set, get killed mid-workout, relaunch, get offered Resume).
///
/// `XCUIApplication.terminate()` + a second `launch()` on the *same* `app`
/// instance is the mechanism: it tears down and restarts the real app
/// process on the simulator, which is what a watchOS force-quit (or a crash)
/// does. The one thing that has to survive that for this test to mean
/// anything is the store itself -- every other `WatchDemoSeed` scenario is
/// deliberately `.inMemory` and vanishes with the process, so these tests
/// opt into an on-disk store via `BURLY_WATCH_UI_TEST_STORE_TOKEN` (see that
/// key's doc in WatchDemoSeed.swift) instead.
final class ResumeUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"
    private static let storeTokenKey = "BURLY_WATCH_UI_TEST_STORE_TOKEN"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The combined crash test: kill the app with two sets already logged
    /// and the rest timer running, relaunch, and check both halves the
    /// spec asks for --
    ///
    /// - §2 acceptance #4: "kill the app process mid-session on the sim →
    ///   relaunch → Resume offered; all previously logged sets present."
    /// - §3 acceptance #3: "Crash with rest timer running (e.g. 40s
    ///   remaining) → relaunch + resume → countdown shows correct
    ///   wall-clock remainder (not reset, not frozen)."
    ///
    /// The rest-timer assertion doesn't try to land on a literal "40s" --
    /// the spec's number is illustrative, and pinning it would mean either
    /// a fragile fixed sleep or a flaky race against the real relaunch
    /// time. Instead this measures the countdown immediately before the
    /// kill and again immediately after Resume, and asserts the post-Resume
    /// reading is meaningfully *lower* -- proof real wall-clock time passed
    /// while the process was dead (rules out "frozen," which would show the
    /// same number) without being anywhere near a fresh 90 s (rules out
    /// "reset").
    func testCrashMidSessionOffersResumeWithLoggedSetsAndCorrectRestRemainder() throws {
        let token = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.storeTokenKey] = token
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15), "Expected the seeded 'Leg Day' routine")
        legDayRow.tap()

        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10), "Expected the logging screen to open")
        XCTAssertEqual(exerciseName.label, "Back Squat")

        let logButton = app.buttons["logSetButton"]
        let setCounter = app.staticTexts["exercisePage.setCounter"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 5))

        // Set 1 of 3 -- prefill is honest from the seeded digest (m2-03),
        // so both taps here log real, non-invented values.
        logButton.tap()
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 2 of 3" })

        // Set 2 of 3. Every log restarts the rest timer (§3: "logging the
        // next set cancels any running timer and starts a fresh one"), so
        // this is also what starts the countdown this test measures.
        logButton.tap()
        XCTAssertTrue(waitFor { setCounter.exists && setCounter.label == "Set 3 of 3" })

        let remaining = app.staticTexts["restTimer.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected the rest timer to auto-start after logging a set")
        let preKillRemaining = try restSeconds(from: remaining.value)

        attachScreenshot(from: app, name: "BurlyWatch-resume-beforeKill")

        // The real crash: tear down the app process entirely, then start it
        // fresh -- not a background/foreground cycle, and not a second
        // `XCUIApplication()` (which would just be a second handle on the
        // same or a different process without proving anything about
        // *this* process's death). Real wall-clock time keeps passing while
        // the process is dead; the sleep below guarantees a meaningful
        // minimum gap on top of whatever `terminate()`/`launch()` overhead
        // already contributes for free.
        app.terminate()
        Thread.sleep(forTimeInterval: 6)
        app.launch()

        let resumeHeading = app.staticTexts["resumeSession.heading"]
        XCTAssertTrue(
            resumeHeading.waitForExistence(timeout: 20),
            "Expected the crash-journaled session to be offered for Resume on relaunch"
        )
        XCTAssertEqual(resumeHeading.label, "Resume workout?")

        let details = app.staticTexts["resumeSession.details"]
        XCTAssertTrue(details.exists)
        XCTAssertTrue(
            details.label.contains("2 sets logged"),
            "Expected both previously-logged sets to be reported, got '\(details.label)'"
        )

        attachScreenshot(from: app, name: "BurlyWatch-resume-offered")

        let resumeButton = app.buttons["resumeSession.resumeButton"]
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
        resumeButton.tap()

        // §2 acceptance #4: "all previously logged sets present" -- both
        // sets survived the crash, and the pager lands on the next unlogged
        // slot rather than back at set 1.
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10), "Expected Resume to reattach to the same logging screen")
        XCTAssertEqual(exerciseName.label, "Back Squat")
        XCTAssertTrue(
            waitFor { setCounter.exists && setCounter.label == "Set 3 of 3" },
            "Expected Resume to land with both previously-logged sets counted, not reset to Set 1"
        )

        // §3 acceptance #3: the countdown after Resume must be a genuine
        // wall-clock continuation, not the same frozen number and not a
        // fresh reset.
        XCTAssertTrue(remaining.waitForExistence(timeout: 5), "Expected the rest timer to still be running after Resume")
        let postResumeRemaining = try restSeconds(from: remaining.value)

        XCTAssertLessThan(
            postResumeRemaining, 90,
            "Expected the countdown to reflect elapsed time, not a fresh 90 s reset"
        )
        XCTAssertGreaterThan(
            postResumeRemaining, 0,
            "Expected the countdown to still be running, not already expired, this soon after logging"
        )
        XCTAssertLessThanOrEqual(
            postResumeRemaining, preKillRemaining - 4,
            "Expected the countdown to have moved forward across the crash gap (not frozen at \(preKillRemaining)s)"
        )

        attachScreenshot(from: app, name: "BurlyWatch-resume-restored")
    }

    /// Sanity guard on the same on-disk-store mechanism: a kill/relaunch
    /// with *no* active session must never spuriously show the Resume
    /// gate, and the store itself (routines, catalog) must survive the
    /// process boundary intact -- otherwise the crash test above would be
    /// unable to tell "Resume correctly offered" from "the whole store
    /// silently reset and happened to look fine."
    func testRelaunchWithNoActiveSessionShowsRoutineListNotResumeGate() throws {
        let token = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.storeTokenKey] = token
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDayRow.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["resumeSession.heading"].exists)

        app.terminate()
        app.launch()

        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 20),
            "Expected the routine list on relaunch with no active session, not the Resume gate"
        )
        XCTAssertFalse(
            app.staticTexts["resumeSession.heading"].exists,
            "The Resume gate must never appear when nothing is active"
        )
    }

    /// m2-06 review finding 1.1: Resume must land on the item the lifter
    /// was actually looking at, not just the first one with something left
    /// to log. **No UI-level pin here on purpose**: Push/Pull's second item
    /// (Bench Press/Pull-Up) is deliberately seeded with no digest (§2
    /// acceptance #5's other half), so logging on it from a UI test
    /// requires raising `reps` from "unset" by hand -- and `RepsControlView`
    /// collapses its +/- buttons into one accessibility-adjustable element
    /// (VoiceOver-friendly, `RepsControlView.swift`'s own doc), which
    /// relies on `XCUIElement.increment()`/`.decrement()` -- not available
    /// on this watchOS XCTest SDK (confirmed by a build failure, not a
    /// guess). Rather than spend this task's last acceptance-sim.sh run
    /// discovering whether some other simulated gesture reaches the same
    /// accessibility action, this fix is pinned at the layer the reviewer's
    /// own guidance pointed at instead: `SessionEngineTests
    /// .setCurrentItemRecordsAndSurvivesRoundTrip` (BurlyCore) and
    /// `ActiveSessionTransactionTests.currentItemIDSurvivesCrashAndResume`
    /// (BurlyPersistence, a real save → cold-reopen → `resumableActiveSession()`
    /// round trip) exercise the exact mechanism deterministically, with no
    /// simulator involved.

    /// m2-06 review finding 4.1: a token containing path syntax (`/`,
    /// `..`) must never be accepted as a filename component -- it must be
    /// rejected and fall back to the ordinary `.inMemory` store, the same
    /// as an absent token, not accepted as a nested or traversing path and
    /// not surfaced as a store-open failure either.
    func testMalformedStoreTokenFallsBackToInMemoryStore() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchEnvironment[Self.storeTokenKey] = "../../etc/evil"
        app.launch()

        let legDayRow = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(
            legDayRow.waitForExistence(timeout: 15),
            "Expected a malformed store token to fall back to the ordinary in-memory store, not fail to open or misbehave"
        )
        XCTAssertFalse(app.staticTexts["storeUnavailableView.heading"].exists)
    }

    // MARK: - Helpers

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Same parsing rule as `LoggingScreenUITests.restSeconds(from:)`: the
    /// countdown's accessibility value is `"<seconds> seconds"`.
    private func restSeconds(from value: Any?) throws -> Int {
        guard let text = value as? String,
              let seconds = Int(text.split(separator: " ", maxSplits: 1).first ?? "") else {
            throw ResumeUITestError.invalidRestTimerValue(String(describing: value))
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

private enum ResumeUITestError: Error {
    case invalidRestTimerValue(String)
}
