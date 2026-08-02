// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Exercises the iPhone app shell (spec m5-01): the four-tab shell, the
/// one-time first-launch welcome with both paths, and the persisted choice
/// that skips the welcome on relaunch.
///
/// Store-backed states come from deterministic, fail-closed in-memory
/// scenarios (m5-01 review finding 6) driven by the launch-environment key
/// BurlyPhone's PhoneDemoSeed matches literally: "empty" (guaranteed-empty
/// store, independent of simulator residue) and "populated" (routines plus
/// a logged session, so real rows must render). A recognized-but-unbuildable
/// scenario ("brokenSeed") must surface as the storage error state, never
/// fall through to the on-device store.
///
/// Welcome persistence uses the DEBUG-only launch arguments WelcomeState
/// matches literally. "-burly-reset-welcome" removes ONLY the namespaced
/// welcome key before the test's first launch, so the relaunch test proves
/// the genuine uncompleted state -> choice -> relaunch-without-overrides
/// (m5-01 review finding 5): a stale `true` left by an earlier test can no
/// longer make the relaunch assertion pass vacuously. Every assertion goes
/// through the stable `accessibilityIdentifier`s the shell's views expose,
/// not through visible copy (m2-01 review finding 6.2), except where the
/// wording itself is the spec contract. The one structural exception is the
/// tab bar buttons: iOS 26's iPhone UITabBarButton ignores
/// accessibilityIdentifier (a known UIKit bug since iOS 10 -- this task's
/// acceptance run failed exactly there), so they are selected by their
/// spec'd titles, which §9 names verbatim.
final class BurlyPhoneUITests: XCTestCase {

    private static let scenarioKey = "BURLY_PHONE_UI_TEST_SCENARIO"
    private static let scenarioEmpty = "empty"
    private static let scenarioPopulated = "populated"
    private static let scenarioBrokenSeed = "brokenSeed"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Shell smoke: History is the default tab, and all four tabs are
    /// reachable. Each tab renders its store-backed empty state on the
    /// seeded EMPTY in-memory store (finding 6), so the assertions never
    /// depend on what the on-device store happens to hold.
    func testTabShellAllTabsReachableWithHistoryDefault() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        // History is the default tab: its empty state is visible immediately.
        let historyEmpty = app.staticTexts["historyTab.emptyState.heading"]
        XCTAssertTrue(
            historyEmpty.waitForExistence(timeout: 15),
            "Expected History (the default tab) to show its empty state on an empty store"
        )

        // Tab bar buttons on iOS 26's iPhone tab bar ignore
        // accessibilityIdentifier (a known UIKit bug since iOS 10; this
        // task's acceptance run failed on `tabBars.buttons["tab.routines"]`
        // for exactly that reason). The buttons do expose their title as
        // the label, and spec §9 names the four tabs verbatim, so each
        // button is selected by its spec'd title -- the same
        // contractual-wording exception as the Import placeholder heading
        // below. The shell still tags each tab item's Label with the
        // `tab.*` identifiers; those propagate on iPad's Liquid Glass
        // toolbar, so both dialects stay in place.
        let tabs: [(button: String, content: String)] = [
            ("Routines", "routinesTab.emptyState.heading"),
            ("Stats", "statsTab.emptyState.heading"),
            ("Settings", "settingsTab.importRow")
        ]
        for tab in tabs {
            let button = app.tabBars.buttons[tab.button]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected tab bar button \\(tab.button)")
            button.tap()
            XCTAssertTrue(
                anyElement(app, identifier: tab.content).waitForExistence(timeout: 5),
                "Expected \\(tab.button) to reveal its tab's content"
            )
            XCTAssertFalse(
                historyEmpty.exists,
                "History content should not remain visible after switching to \\(tab.button)"
            )
        }

        // And back to the default tab.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            historyEmpty.waitForExistence(timeout: 5),
            "Expected History to be reachable again"
        )

        attachScreenshot(from: app, name: "BurlyPhone-tabShell")
    }

    /// First-launch path A: welcome -> Start fresh -> the tab shell. The
    /// welcome is asserted from the GENUINE uncompleted state: the reset
    /// argument removed the persisted key, and no force/skip override is
    /// used (finding 5).
    func testFirstLaunchStartFreshLandsInTabs() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-reset-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on a genuinely uncompleted first launch"
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
    ///
    /// The Import choice also persists (finding 5): both welcome buttons
    /// call the same `WelcomeState.markCompleted()`, so a relaunch without
    /// any welcome arguments skips the welcome after Import too — not just
    /// after Start fresh.
    func testFirstLaunchImportShowsPlaceholder() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-reset-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on a genuinely uncompleted first launch"
        )

        app.buttons["welcomeView.importButton"].tap()

        let heading = app.staticTexts["importPlaceholderView.heading"]
        XCTAssertTrue(
            heading.waitForExistence(timeout: 15),
            "Expected Import from Hevy to navigate to the placeholder screen"
        )
        XCTAssertEqual(heading.label, "Import from Hevy")
        app.terminate()

        // The Import choice persisted the welcome flag: a relaunch with no
        // welcome arguments lands in the tab shell.
        let relaunched = XCUIApplication()
        relaunched.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        relaunched.launch()
        XCTAssertTrue(
            relaunched.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected the Import choice to persist: a relaunch lands in the tab shell"
        )
        XCTAssertFalse(
            relaunched.staticTexts["welcomeView.heading"].exists,
            "Expected the welcome to be skipped on relaunch after choosing Import"
        )

        attachScreenshot(from: relaunched, name: "BurlyPhone-importPlaceholder")
    }

    /// The choice persists: the first launch starts from the GENUINE
    /// uncompleted state (reset argument removes ONLY the welcome key; no
    /// force argument), the user makes a real choice, and a relaunch with
    /// no welcome arguments at all skips the welcome. If `markCompleted()`
    /// were removed or broken, the key would still be gone and the welcome
    /// would show again — the old force-argument shape could pass on a
    /// stale `true` left by an earlier test (finding 5).
    func testWelcomeSkippedOnRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-reset-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on a genuinely uncompleted first launch"
        )
        app.buttons["welcomeView.startFreshButton"].tap()
        XCTAssertTrue(
            app.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected Start fresh to land in the tab shell"
        )
        app.terminate()

        // Relaunch without any welcome overrides: the persisted choice skips
        // the welcome. The scenario stays "empty" only so the landing
        // assertion is deterministic — it is not a welcome override.
        let relaunched = XCUIApplication()
        relaunched.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
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

    /// Finding 6, populated side: the seeded store's real rows must render —
    /// History shows the logged-session row (keyed by session id), Stats
    /// shows the workout count, Routines shows the two seeded routines
    /// (keyed by routine id, finding 8). A shell that hardcodes empty states
    /// fails here.
    func testPopulatedScenarioRendersRealRows() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioPopulated
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        // History (default tab) shows the seeded logged session, keyed by
        // its id — the id is a PhoneDemoSeed.SeededIDs literal, matched
        // verbatim here (the UI test target cannot share code with the app).
        let sessionRow = app.staticTexts["historyTab.sessionRow.6F4E2C1A-0000-4000-8000-000000000003"]
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: 15),
            "Expected the seeded logged session to render as a History row"
        )

        // Stats shows the scalar workout count, not an empty state.
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(
            app.staticTexts["statsTab.workoutCountRow"].waitForExistence(timeout: 5),
            "Expected Stats to show the workout count on the populated store"
        )

        // Routines shows the seeded routines, each keyed by its id.
        app.tabBars.buttons["Routines"].tap()
        XCTAssertTrue(
            app.staticTexts["routinesTab.routineRow.6F4E2C1A-0000-4000-8000-000000000001"].waitForExistence(timeout: 5),
            "Expected the seeded Leg Day routine to render as a Routines row"
        )
        XCTAssertTrue(
            app.staticTexts["routinesTab.routineRow.6F4E2C1A-0000-4000-8000-000000000002"].waitForExistence(timeout: 5),
            "Expected the seeded Push/Pull routine to render as a Routines row"
        )

        attachScreenshot(from: app, name: "BurlyPhone-populatedRows")
    }

    /// Finding 6, fail-closed side: once a scenario is recognized, a seed
    /// that cannot be built must surface as the storage error state — never
    /// fall through to the on-device store, never render as an ordinary
    /// empty state. `PhoneDemoSeed.Scenario.brokenSeed` exists solely to
    /// exercise this path deterministically.
    func testBrokenSeedFailsClosedToStorageError() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioBrokenSeed
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["storeUnavailableView.heading"].waitForExistence(timeout: 15),
            "Expected a recognized-but-unbuildable scenario to surface as the storage error state"
        )
        XCTAssertFalse(
            app.staticTexts["historyTab.emptyState.heading"].exists,
            "Expected no tab-shell content behind a fail-closed seed error"
        )

        attachScreenshot(from: app, name: "BurlyPhone-brokenSeedFailClosed")
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
