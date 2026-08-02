// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Exercises the watch app shell (spec §2 routine list, §5 fresh install)
/// via `launchEnvironment` scenarios that BurlyWatch's WatchDemoSeed (a
/// DEBUG-only seam, since BurlySync's snapshot/digest transport does not
/// exist yet) turns into a deterministic in-memory store. The environment
/// key and its three values are matched literally against
/// BurlyWatch/WatchDemoSeed.swift -- this target runs out-of-process and
/// has no other way to reach into the app under test.
///
/// Selection goes through the stable `accessibilityIdentifier`s BurlyWatch's
/// views expose, not through visible copy (m2-01 review finding 6.2) --
/// except "Waiting for iPhone," where the wording itself is the §5 contract,
/// so it is asserted both ways.
final class BurlyWatchUITests: XCTestCase {

    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// §5: "empty store + no digest renders a 'waiting for iPhone' state."
    func testEmptyStoreShowsWaitingForPhone() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "empty"
        app.launch()

        let title = app.staticTexts["waitingForPhoneView.headline"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 15),
            "Expected the waiting-for-iPhone state on an empty watch store"
        )
        // The wording itself is the §5 contract here, so it stays asserted
        // alongside the identifier (m2-01 review finding 6.2).
        XCTAssertEqual(title.label, "Waiting for iPhone")

        attachScreenshot(from: app, name: "BurlyWatch-waitingForPhone")
    }

    /// §2: routine list renders seeded routines with their "last done N
    /// days ago" text, the list-end "Empty session" secondary action is
    /// present, and Start pushes to a real (if stubbed) destination.
    func testSeededRoutinesRenderInList() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDay = app.staticTexts["routineRow.Leg Day.name"]
        XCTAssertTrue(legDay.waitForExistence(timeout: 15), "Expected seeded routine 'Leg Day' in the list")
        XCTAssertTrue(
            app.staticTexts["routineRow.Push/Pull.name"].exists,
            "Expected seeded routine 'Push/Pull' in the list"
        )
        // Existence only: relative-date phrasing ("Last done N days ago")
        // is not the contract, so this doesn't couple to its exact wording
        // (m2-01 review finding 6.2).
        XCTAssertTrue(
            app.staticTexts["routineRow.Leg Day.lastDone"].exists,
            "Expected the seeded logged session's last-done row"
        )
        XCTAssertTrue(
            app.staticTexts["routineRow.Push/Pull.lastDone"].exists,
            "Expected the never-logged routine's last-done row"
        )
        XCTAssertTrue(
            anyElement(app, identifier: "emptySessionRow").exists,
            "Expected the §2 list-end 'Empty session' secondary action"
        )

        attachScreenshot(from: app, name: "BurlyWatch-routineList")

        // m2-03: Start now pushes the real logging screen (SessionEntryView
        // -> LoggingScreenView), not the m2-01 stub -- see
        // LoggingScreenUITests.swift for the full session-flow coverage
        // this unlocks (spec §2 acceptance #3/#5). This test's job stays the
        // routine list's own contract: Start reaches a real, non-dead-end
        // destination naming the routine that was tapped.
        legDay.tap()
        let exerciseName = app.staticTexts["exercisePage.name"]
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 10), "Expected Start to navigate to the real logging screen")
        XCTAssertEqual(exerciseName.label, "Back Squat", "Expected Leg Day's own exercise on the logging screen")

        attachScreenshot(from: app, name: "BurlyWatch-startLoggingScreen")
    }

    /// m2-01 review findings 2.1/2.2: once a recognized scenario is
    /// requested, a seed that fails to build must fail *closed* -- surfaced
    /// as an error state, never silently falling through to the real
    /// on-device store and never rendering as an ordinary empty/waiting
    /// state. `WatchDemoSeed.Scenario.brokenSeed` exists solely to exercise
    /// this path deterministically.
    func testBrokenSeedScenarioFailsClosedToErrorState() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "brokenSeed"
        app.launch()

        let heading = app.staticTexts["storeUnavailableView.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 15),
            "Expected a store-unavailable error state when the requested seed scenario fails to build"
        )
        XCTAssertFalse(
            app.staticTexts["waitingForPhoneView.headline"].exists,
            "A failed seed must not be indistinguishable from an empty store's waiting-for-iPhone state"
        )

        attachScreenshot(from: app, name: "BurlyWatch-brokenSeed")
    }

    /// m2-03 review finding 12 (carried gap, closed): once the launch-
    /// environment key is present, an unrecognized value must fail closed
    /// -- never fall through to the real on-device store. Mirrors
    /// `testBrokenSeedScenarioFailsClosedToErrorState` above; this is the
    /// "typo'd scenario name" half of the same fail-closed contract
    /// (mirrors BurlyPhone's PhoneDemoSeed fix, m5-01 review round 2
    /// finding 2).
    func testUnrecognizedScenarioValueFailsClosedToErrorState() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routine" // typo of "routines"
        app.launch()

        let heading = app.staticTexts["storeUnavailableView.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 15),
            "Expected a store-unavailable error state for an unrecognized scenario value"
        )
        XCTAssertFalse(
            app.staticTexts["waitingForPhoneView.headline"].exists,
            "An unrecognized scenario value must not render as the ordinary empty-store waiting state"
        )

        attachScreenshot(from: app, name: "BurlyWatch-unrecognizedScenario")
    }

    /// Looks a stable identifier up regardless of the accessibility element
    /// type SwiftUI/watchOS happens to expose it as (`.cell`, `.button`,
    /// `.other`, ...) -- used for containers like the "Empty session" row,
    /// where that type isn't part of the contract either.
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
