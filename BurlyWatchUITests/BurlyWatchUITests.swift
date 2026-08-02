// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Exercises the watch app shell (spec §2 routine list, §5 fresh install)
/// via `launchEnvironment` scenarios that BurlyWatch's WatchDemoSeed (a
/// DEBUG-only seam, since BurlySync's snapshot/digest transport does not
/// exist yet) turns into a deterministic in-memory store. The environment
/// key and its two values are matched literally against
/// BurlyWatch/WatchDemoSeed.swift -- this target runs out-of-process and
/// has no other way to reach into the app under test.
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

        let title = app.staticTexts["Waiting for iPhone"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 15),
            "Expected the waiting-for-iPhone state on an empty watch store"
        )

        attachScreenshot(from: app, name: "BurlyWatch-waitingForPhone")
    }

    /// §2: routine list renders seeded routines with their "last done N
    /// days ago" text, the list-end "Empty session" secondary action is
    /// present, and Start pushes to a real (if stubbed) destination.
    func testSeededRoutinesRenderInList() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        let legDay = app.staticTexts["Leg Day"]
        XCTAssertTrue(legDay.waitForExistence(timeout: 15), "Expected seeded routine 'Leg Day' in the list")
        XCTAssertTrue(app.staticTexts["Push/Pull"].exists, "Expected seeded routine 'Push/Pull' in the list")
        XCTAssertTrue(
            app.staticTexts["Last done 3 days ago"].exists,
            "Expected the seeded logged session's last-done text"
        )
        XCTAssertTrue(
            app.staticTexts["Never done"].exists,
            "Expected the never-logged routine's fallback last-done text"
        )
        XCTAssertTrue(
            app.staticTexts["Empty session"].exists,
            "Expected the §2 list-end 'Empty session' secondary action"
        )

        attachScreenshot(from: app, name: "BurlyWatch-routineList")

        legDay.tap()
        let stubHeading = app.staticTexts["Starting Leg Day"]
        XCTAssertTrue(stubHeading.waitForExistence(timeout: 5), "Expected Start to navigate to the session stub")

        attachScreenshot(from: app, name: "BurlyWatch-startStub")
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
