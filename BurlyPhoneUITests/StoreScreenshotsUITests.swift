// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// The App Store screenshots for iPhone, not an acceptance test: one pass
/// through the app on PhoneDemoSeed's synthetic `storeScreenshots` program,
/// attaching each screen under the name its file gets in
/// fastlane/screenshots/en-US. Scripts/capture-store-screenshots.sh runs it
/// on an iPhone 17 Pro Max (1320 × 2868, App Store Connect's 6.9" slot) with
/// BURLY_STORE_SCREENSHOTS=1. Every other run skips it, so the acceptance
/// gate never pays for it.
///
/// Pounds: every UI-test launch resets the display unit to kg, but only in
/// the app's persistent defaults (DisplayUnitPreference). A `-<key> lb`
/// launch-argument pair lands in the argument domain, which outranks them
/// for every read in this process, and nothing of it persists past the run.
///
/// Waits go through stable identifiers and nothing asserts layout, so a
/// screen that grows or reflows (larger text, a new row) still captures.
/// The seeded ids are PhoneDemoSeed.StoreScreenshotIDs, repeated here
/// because this target cannot import the app.
final class StoreScreenshotsUITests: XCTestCase {

    private static let pushRoutineID = "6F4E2C1A-0000-4000-8000-0000000000A1"
    private static let newestSessionID = "6F4E2C1A-0000-4000-8000-0000000000A4"
    private static let backSquatExerciseID = "10000000-0000-4000-8000-000000000063"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BURLY_STORE_SCREENSHOTS"] == "1",
            "App Store screenshots run only from Scripts/capture-store-screenshots.sh (BURLY_STORE_SCREENSHOTS=1)"
        )
        continueAfterFailure = false
    }

    func testCaptureStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BURLY_PHONE_UI_TEST_SCENARIO"] = "storeScreenshots"
        // The unit pair goes first: the argument domain reads "-key value"
        // pairs, and the welcome flag is matched on its own.
        app.launchArguments += ["-com.burly.lifting.displayUnit", "lb", "-burly-skip-welcome"]
        app.launch()

        // History: weeks of sessions, the newest with a PR.
        let newestRow = anyElement(app, identifier: "historyTab.sessionRow.\(Self.newestSessionID)")
        XCTAssertTrue(newestRow.waitForExistence(timeout: 20), "Expected the seeded history")
        XCTAssertTrue(
            anyElement(app, identifier: "historyTab.prBadge.\(Self.newestSessionID)").exists,
            "Expected the newest session to carry a PR badge"
        )
        XCTAssertTrue(newestRow.label.contains(" lb"), "Expected volume in pounds, got '\(newestRow.label)'")
        capture("01_iphone_history")

        // The newest session's sets, without the DEBUG revision row.
        newestRow.tap()
        XCTAssertTrue(
            anyElement(app, identifier: "historyDetail.exercise.\(Self.backSquatExerciseID)").waitForExistence(timeout: 10),
            "Expected the session detail"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", " lb × ")).firstMatch.exists,
            "Expected set rows in pounds"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Revision ")).firstMatch.exists,
            "The store screenshot must not show the DEBUG revision row"
        )
        capture("02_iphone_session")

        // Stats, top: Back Squat's progression.
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(
            anyElement(app, identifier: "statsTab.progression.chart").waitForExistence(timeout: 20),
            "Expected the progression chart"
        )
        capture("03_iphone_progression")

        // Stats, further down: weekly volume above the muscle split.
        let volumeTitle = app.staticTexts["Weekly volume"]
        XCTAssertTrue(volumeTitle.waitForExistence(timeout: 5), "Expected the weekly volume card")
        scrollUntilTop(of: volumeTitle, isBelowNavigationBarIn: app)
        XCTAssertTrue(anyElement(app, identifier: "statsTab.volume.chart").exists, "Expected the weekly volume chart")
        XCTAssertTrue(anyElement(app, identifier: "statsTab.muscleSplit.chart").exists, "Expected the muscle split chart")
        capture("04_iphone_volume")

        // The routine builder, on Push. The row is a plain-style button, so
        // only its text takes a tap (a tap at the row's center misses).
        app.tabBars.buttons["Routines"].tap()
        let push = app.staticTexts["routinesTab.routineRow.\(Self.pushRoutineID)"]
        XCTAssertTrue(push.waitForExistence(timeout: 10), "Expected the seeded Push routine")
        push.tap()
        XCTAssertTrue(
            anyElement(app, identifier: "routineEditor.nameField.\(Self.pushRoutineID)").waitForExistence(timeout: 10),
            "Expected the routine editor"
        )
        capture("05_iphone_routine")

        // Settings, with the Apple Health row clear of the tab bar.
        app.tabBars.buttons["Settings"].tap()
        let openHealth = anyElement(app, identifier: "settingsTab.openHealth")
        XCTAssertTrue(anyElement(app, identifier: "settingsTab.healthRow").waitForExistence(timeout: 10), "Expected the Apple Health row")
        XCTAssertTrue(anyElement(app, identifier: "settingsTab.unitOption.lb").isSelected, "Expected pounds to be selected")
        let tabBar = app.tabBars.firstMatch
        let isClearOfTabBar = { openHealth.exists && openHealth.frame.maxY < tabBar.frame.minY - 12 }
        for _ in 0..<4 where !isClearOfTabBar() {
            drag(app, by: openHealth.exists ? openHealth.frame.maxY - tabBar.frame.minY + 24 : 300)
        }
        XCTAssertTrue(isClearOfTabBar(), "Expected Open Health above the tab bar")
        capture("06_iphone_settings")
    }

    // MARK: - Helpers

    /// Scrolls with slow, held drags (no fling, so the offset is exact)
    /// until `element`'s top sits just below the navigation bar, which
    /// shrinks from its large title on the way.
    private func scrollUntilTop(of element: XCUIElement, isBelowNavigationBarIn app: XCUIApplication) {
        let navigationBar = app.navigationBars.firstMatch
        for _ in 0..<6 {
            let distance = element.frame.minY - (navigationBar.frame.maxY + 12)
            guard abs(distance) > 8 else { return }
            drag(app, by: distance)
        }
    }

    /// Moves the content up by `distance` points (down when negative).
    private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        let limited = max(-500, min(500, distance))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: limited > 0 ? 0.75 : 0.3))
        let end = start.withOffset(CGVector(dx: 0, dy: -limited))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The whole screen, status bar included, after a moment for any
    /// push, tab switch or chart layout to finish.
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
