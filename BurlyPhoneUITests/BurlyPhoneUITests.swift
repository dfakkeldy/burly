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
/// fall through to the on-device store — and so must a value that matches
/// no known scenario at all (m5-01 review round 2, finding 2): only an
/// absent key legitimately falls through.
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
    /// Deliberately not a `PhoneDemoSeed.Scenario` case — see
    /// `testUnrecognizedScenarioFailsClosedToStorageError`.
    private static let scenarioUnrecognized = "definitelyNotARealScenario"

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
            ("Stats", "statsTab.progression.empty"),
            ("Settings", "settingsTab.importRow")
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

    /// Finding 6, populated side: the seeded store's real rows and all four
    /// §7 charts must render. The fixture spans a year and includes recent
    /// multi-tag plus unattributed working sets, so a chart implementation
    /// cannot pass by hardcoding a non-empty shell state.
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

        // Stats has one stable leaf identifier per real chart. These
        // assertions intentionally do not inspect chart-renderer internals;
        // they prove each chart's data branch rather than its empty branch.
        app.tabBars.buttons["Stats"].tap()
        for chartIdentifier in [
            "statsTab.progression.chart",
            "statsTab.volume.chart",
            "statsTab.muscleSplit.chart",
            "statsTab.consistency.chart"
        ] {
            XCTAssertTrue(
                anyElement(app, identifier: chartIdentifier).waitForExistence(timeout: 15),
                "Expected populated scenario to render \(chartIdentifier)"
            )
        }

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

    /// Spec §9 acceptance #3 (routine + custom portion): this uses the
    /// deterministic empty scenario, which now contains the real curated
    /// catalog but no user-authored routines/history. It proves an actual
    /// phone authoring sequence, rather than an existence-only mock:
    /// custom creation with two selected tags, routine creation, catalog
    /// insertion, count/rest edits, item reorder, save, and both archive
    /// paths. Dynamic entities are selected through stable identifier
    /// prefixes; the final assertions inspect rendered values and order.
    func testRoutineBuilderCatalogCustomAndArchiveFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        app.tabBars.buttons["Routines"].tap()
        XCTAssertTrue(app.staticTexts["routinesTab.emptyState.heading"].waitForExistence(timeout: 15))

        // Custom exercise creation exposes the frozen taxonomy as tappable,
        // identifier-backed values. Assert both the custom name and its
        // selected tags after the store-backed catalog reload.
        app.buttons["routinesTab.catalogButton"].tap()
        XCTAssertTrue(app.buttons["catalog.newCustomExerciseButton"].waitForExistence(timeout: 10))
        app.buttons["catalog.newCustomExerciseButton"].tap()
        let customName = "UI Test Cable Curl"
        let customNameField = app.textFields["catalog.custom.nameField"]
        XCTAssertTrue(customNameField.waitForExistence(timeout: 5))
        customNameField.tap()
        customNameField.typeText(customName)
        app.buttons["catalog.custom.muscleTag.biceps"].tap()
        app.buttons["catalog.custom.muscleTag.forearms"].tap()
        XCTAssertEqual(app.buttons["catalog.custom.muscleTag.biceps"].value as? String, "Selected")
        app.buttons["catalog.custom.createButton"].tap()

        // The catalog is sorted alphabetically by name (~100 curated rows)
        // and SwiftUI's List only materializes on-screen rows into the
        // accessibility tree. A freshly created "U"-named custom exercise
        // sorts well past the initial viewport, so it never appears to
        // `waitForExistence` without first narrowing the list -- exactly
        // like the archive step below already does. Search by the new name
        // to bring its row on-screen before asserting it rendered.
        let catalogSearch = app.searchFields["Search exercises"]
        XCTAssertTrue(catalogSearch.waitForExistence(timeout: 5))
        catalogSearch.tap()
        catalogSearch.typeText(customName)
        XCTAssertTrue(app.staticTexts[customName].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Biceps · Forearms"].exists)

        // The toolbar's Done button is unreachable while search is active:
        // SwiftUI replaces the whole toolbar (Done + Custom exercise) with
        // the search field's own controls for as long as search stays
        // presented -- dismissing the keyboard alone isn't enough. Cancel
        // search via its own control (accessibility label "close", per the
        // live accessibility tree) to restore the normal toolbar first.
        app.buttons["close"].tap()
        XCTAssertTrue(app.buttons["catalog.doneButton"].waitForExistence(timeout: 5))
        app.buttons["catalog.doneButton"].tap()

        // Create a routine and add two actual curated catalog exercises by
        // their frozen catalog UUIDs. Searching keeps the second selection
        // independent of the list's off-screen virtualization.
        app.buttons["routinesTab.newRoutineButton"].tap()
        let routineName = "UI Test Strength"
        let routineNameField = app.textFields["routineCreator.nameField"]
        XCTAssertTrue(routineNameField.waitForExistence(timeout: 5))
        routineNameField.tap()
        routineNameField.typeText(routineName)
        app.buttons["routineCreator.createButton"].tap()
        XCTAssertTrue(app.buttons["routineEditor.addExerciseButton"].waitForExistence(timeout: 10))

        app.buttons["routineEditor.addExerciseButton"].tap()
        XCTAssertTrue(app.buttons["catalog.addExercise.10000000-0000-4000-8000-000000000001"].waitForExistence(timeout: 10))
        app.buttons["catalog.addExercise.10000000-0000-4000-8000-000000000001"].tap()

        app.buttons["routineEditor.addExerciseButton"].tap()
        let search = app.searchFields["Search exercises"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Back Squat")
        XCTAssertTrue(app.buttons["catalog.addExercise.10000000-0000-4000-8000-000000000063"].waitForExistence(timeout: 10))
        app.buttons["catalog.addExercise.10000000-0000-4000-8000-000000000063"].tap()

        // The first inserted row is Bench Press. Change both independent
        // item fields and assert their displayed values before saving.
        let setCount = firstElement(app, identifierPrefix: "routineEditor.itemSetCount.")
        XCTAssertTrue(setCount.waitForExistence(timeout: 5))
        XCTAssertEqual(setCount.label, "3 sets")
        let increment = firstElement(app, identifierPrefix: "routineEditor.increaseSetCount.")
        increment.tap()
        XCTAssertEqual(setCount.label, "4 sets")

        let restMenu = firstElement(app, identifierPrefix: "routineEditor.restMenu.")
        restMenu.tap()
        app.buttons["90 sec"].tap()
        XCTAssertTrue(firstElement(app, identifierPrefix: "routineEditor.restMenu.").label.contains("90 sec"))

        // Explicit move controls are available alongside List edit-mode
        // reordering for VoiceOver/Dynamic Type. The frame assertion proves
        // the rendered order changed, not merely that the control existed.
        firstElement(app, identifierPrefix: "routineEditor.moveDown.").tap()
        let bench = app.staticTexts["Barbell Bench Press"]
        let squat = app.staticTexts["Back Squat"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(bench.frame.minY, squat.frame.minY)

        app.buttons["routineEditor.saveButton"].tap()
        XCTAssertTrue(firstElement(app, identifierPrefix: "routineEditor.itemSetCount.").label.contains("4"))
        app.buttons["routineEditor.archiveButton"].tap()
        app.buttons["Archive routine"].tap()
        XCTAssertTrue(app.staticTexts["routinesTab.emptyState.heading"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[routineName].exists)

        // Archive the custom exercise through its catalog lifecycle too.
        app.buttons["routinesTab.catalogButton"].tap()
        let archiveSearch = app.searchFields["Search exercises"]
        XCTAssertTrue(archiveSearch.waitForExistence(timeout: 5))
        archiveSearch.tap()
        archiveSearch.typeText(customName)
        XCTAssertTrue(app.staticTexts[customName].waitForExistence(timeout: 5))
        let archiveButton = firstElement(app, identifierPrefix: "catalog.archiveExercise.")
        archiveButton.tap()
        app.buttons["Archive exercise"].tap()
        XCTAssertFalse(app.staticTexts[customName].exists)

        attachScreenshot(from: app, name: "BurlyPhone-routineBuilderCatalog")
    }

    /// Spec §7 acceptance #3, empty side: each independently meaningful
    /// chart has a genuine empty state on a deterministic empty history.
    /// This catches both crashes during chart construction and a misleading
    /// dashboard-level substitute that hides which stat lacks data.
    func testStatsChartsShowIndependentEmptyStates() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        app.tabBars.buttons["Stats"].tap()
        for emptyIdentifier in [
            "statsTab.progression.empty",
            "statsTab.volume.empty",
            "statsTab.muscleSplit.empty",
            "statsTab.consistency.empty"
        ] {
            XCTAssertTrue(
                app.staticTexts[emptyIdentifier].waitForExistence(timeout: 15),
                "Expected empty history to show \(emptyIdentifier)"
            )
        }
        XCTAssertFalse(anyElement(app, identifier: "statsTab.progression.chart").exists)

        attachScreenshot(from: app, name: "BurlyPhone-statsEmpty")
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

    /// m5-01 review round 2, finding 2: a launch-environment value that
    /// doesn't match any `PhoneDemoSeed.Scenario` case (a typo, on either
    /// side of the app/test boundary) must fail closed exactly like
    /// `.brokenSeed` — never fall through to the real on-device store, the
    /// fail-open trap `PhoneDemoSeed.requestedStore()` had before this fix
    /// collapsed "key absent" and "key present but unrecognized" into the
    /// same `nil`. The message identifier is asserted, not just the
    /// heading, so this is provably the unrecognized-scenario error and not
    /// some other failure that happens to share the same heading.
    func testUnrecognizedScenarioFailsClosedToStorageError() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioUnrecognized
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["storeUnavailableView.heading"].waitForExistence(timeout: 15),
            "Expected an unrecognized scenario value to surface as the storage error state"
        )
        let message = app.staticTexts["storeUnavailableView.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(
            message.label.contains("unrecognizedScenario"),
            "Expected a distinct message identifying an unrecognized scenario, got: \(message.label)"
        )
        XCTAssertFalse(
            app.staticTexts["historyTab.emptyState.heading"].exists,
            "Expected no tab-shell content behind a fail-closed unrecognized-scenario error"
        )

        attachScreenshot(from: app, name: "BurlyPhone-unrecognizedScenarioFailClosed")
    }

    /// Looks a stable identifier up regardless of the accessibility element
    /// type SwiftUI happens to expose it as (`.cell`, `.button`, `.other`,
    /// ...) -- used for containers like the settings rows, where that type
    /// isn't part of the contract either.
    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Dynamic rows use UUID-qualified identifiers. UI tests do not know a
    /// user-created UUID ahead of time, so select the one visible matching
    /// element by its stable control prefix, then assert its concrete value.
    private func firstElement(_ app: XCUIApplication, identifierPrefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .firstMatch
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
