// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Exercises the iPhone app shell (spec m5-01): the four-tab shell, the
/// one-time first-launch welcome with both paths, and the persisted choice
/// that skips the welcome on relaunch.
///
/// The welcome's persistence lives in UserDefaults, so tests that need a
/// *deterministic* side use the DEBUG-only launch arguments BurlyPhone's
/// WelcomeState matches literally -- "-burly-force-welcome" (show the
/// welcome regardless of persisted state) and "-burly-skip-welcome" (skip
/// it regardless) -- the same out-of-process seam pattern as
/// BurlyWatchUITests + WatchDemoSeed. Every assertion goes through the
/// stable `accessibilityIdentifier`s the shell's views expose, not through
/// visible copy (m2-01 review finding 6.2), except where the wording itself
/// is the spec contract.
final class BurlyPhoneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Shell smoke: History is the default tab, and all four tabs are
    /// reachable. Each tab renders its store-backed empty state on a fresh
    /// install (the phone store starts empty -- nothing in this task writes
    /// to it), so each tab is asserted by its own empty-state heading.
    func testTabShellAllTabsReachableWithHistoryDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        // History is the default tab: its empty state is visible immediately.
        let historyEmpty = app.staticTexts["historyTab.emptyState.heading"]
        XCTAssertTrue(
            historyEmpty.waitForExistence(timeout: 15),
            "Expected History (the default tab) to show its empty state on a fresh store"
        )

        let tabs: [(button: String, content: String)] = [
            ("tab.routines", "routinesTab.emptyState.heading"),
            ("tab.stats", "statsTab.emptyState.heading"),
            ("tab.settings", "settingsTab.importRow")
        ]
        for tab in tabs {
            let button = app.tabBars.buttons[tab.button]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected tab bar button \(tab.button)")
            button.tap()
            XCTAssertTrue(
                anyElement(app, identifier: tab.content).waitForExistence(timeout: 5),
                "Expected \(tab.button) to reveal its tab's content"
            )
            XCTAssertFalse(
                historyEmpty.exists,
                "History content should not remain visible after switching to \(tab.button)"
            )
        }

        // And back to the default tab.
        app.tabBars.buttons["tab.history"].tap()
        XCTAssertTrue(
            historyEmpty.waitForExistence(timeout: 5),
            "Expected History to be reachable again"
        )

        attachScreenshot(from: app, name: "BurlyPhone-tabShell")
    }

    /// First-launch path A: welcome -> Start fresh -> the tab shell.
    func testFirstLaunchStartFreshLandsInTabs() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-burly-force-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on first launch"
        )

        app.buttons["welcomeView.startFreshButton"].tap()

        XCTAssertTrue(
            app.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected Start fresh to land in the tab shell on History"
        )

        attachScreenshot(from: app, name: "BurlyPhone-startFresh")
    }

    /// First-launch path B: welcome -> Import from Hevy -> the clearly-
    /// labeled placeholder screen. The heading's wording is asserted because
    /// "clearly labeled" is the spec contract for this placeholder.
    func testFirstLaunchImportShowsPlaceholder() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-burly-force-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on first launch"
        )

        app.buttons["welcomeView.importButton"].tap()

        let heading = app.staticTexts["importPlaceholderView.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 15),
            "Expected Import from Hevy to navigate to the placeholder screen"
        )
        XCTAssertEqual(heading.label, "Import from Hevy")

        attachScreenshot(from: app, name: "BurlyPhone-importPlaceholder")
    }

    /// The choice persists: after completing the welcome for real (persisted
    /// to UserDefaults, no launch-argument override), a relaunch skips the
    /// welcome and lands directly in the tab shell.
    func testWelcomeSkippedOnRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-burly-force-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on first launch"
        )
        app.buttons["welcomeView.startFreshButton"].tap()
        XCTAssertTrue(
            app.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected Start fresh to land in the tab shell"
        )
        app.terminate()

        // Relaunch without overrides: the persisted choice skips the welcome.
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(
            relaunched.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected a relaunch after the first-launch choice to land in the tab shell"
        )
        XCTAssertFalse(
            relaunched.staticTexts["welcomeView.heading"].exists,
            "Expected the welcome to be skipped on relaunch once the choice persists"
        )

        attachScreenshot(from: relaunched, name: "BurlyPhone-relaunchSkipsWelcome")
    }

    /// Looks a stable identifier up regardless of the accessibility element
    /// type SwiftUI happens to expose it as (`.cell`, `.button`, `.other`,
    /// ...) -- used for containers like the settings rows, where that type
    /// isn't part of the contract either.
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
