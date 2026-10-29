// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// The Hevy CSV import flow end to end (spec §8; task m7-02): welcome ->
/// Import from Hevy -> preview -> import -> summary -> History, then the
/// same file again from Settings previews zero new workouts.
///
/// The system document picker is not drivable by XCUITest, so these tests
/// set BurlyPhone's DEBUG-only `HevyImportUITestFixture` launch-environment
/// key: "Choose CSV File" then reads the app's bundled SYNTHETIC export
/// (`BurlyPhone/Preview Content/HevySyntheticFixture.csv`) instead of
/// presenting the picker. Everything after that — parse, plan, preview,
/// store writes, History refresh — is the real path.
///
/// Expected numbers for that fixture, repeated here because this
/// out-of-process target cannot import the app (BurlyKit's
/// `HevyImportPlanTests.appUITestFixtureParsesToTheNumbersTheUITestAsserts`
/// pins the same numbers against the parser):
///   3 workouts, 7 sets, 3 exercises matched (all via Hevy aliases),
///   1 new custom exercise, 1 cardio row, 1 RPE value, 2 superset rows,
///   1 failure marker, 1 malformed row (row 10: reps "eight"), no encoding
///   damage, nothing lost to an unclosed quote.
///
/// Each preview/summary number is one accessibility element whose value is
/// the number (the same element VoiceOver reads), so these assertions read
/// `XCUIElement.value` by stable identifier rather than visible copy.
///
/// Spec §8 acceptance #3 ("import writes zero HKWorkouts") is enforced
/// below the UI — BurlyImport cannot reach HealthKit and the plan forces
/// every imported session's HealthKit link to nil (unit-tested in
/// BurlyKit). The UI-level stand-in here: an imported session's detail
/// shows no linked HealthKit workout.
///
/// `@MainActor` because XCUIElement's API is main-actor isolated under the
/// Swift 6 language mode; `continueAfterFailure` is set per test instead of
/// in a (nonisolated) `setUpWithError` override.
@MainActor
final class ImportUITests: XCTestCase {

    // Matched literally by BurlyPhone's PhoneDemoSeed and
    // HevyImportUITestFixture (no shared code across the process boundary).
    private static let scenarioKey = "BURLY_PHONE_UI_TEST_SCENARIO"
    private static let scenarioEmpty = "empty"
    private static let fixtureKey = "BURLY_PHONE_UI_TEST_HEVY_FIXTURE"
    private static let fixtureSynthetic = "synthetic"

    func testWelcomeImportPreviewMatchesSummaryThenReimportAddsNothing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchEnvironment[Self.fixtureKey] = Self.fixtureSynthetic
        app.launchArguments += ["-burly-reset-welcome"]
        app.launch()

        // Welcome -> Import from Hevy -> intro.
        XCTAssertTrue(
            app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15),
            "Expected the welcome screen on a genuinely uncompleted first launch"
        )
        app.buttons["welcomeView.importButton"].tap()
        XCTAssertTrue(
            app.staticTexts["hevyImport.intro.heading"].waitForExistence(timeout: 15),
            "Expected Import from Hevy to open the import intro"
        )
        app.buttons["hevyImport.chooseFileButton"].tap()

        // Preview: workouts, exercises, and the dropped-data report.
        assertCount(app, "hevyImport.preview.newWorkouts", 3, waitForIt: true)
        assertCount(app, "hevyImport.preview.alreadyImported", 0)
        assertCount(app, "hevyImport.preview.sets", 7)
        XCTAssertTrue(element(app, "hevyImport.preview.dateRange").exists, "Expected the preview's date range")
        let timeZoneNote = scrollTo(app, "hevyImport.preview.timeZone")
        XCTAssertTrue(timeZoneNote.label.hasPrefix("Times read as "), "Expected the time-zone assumption to be stated")
        assertCount(app, "hevyImport.preview.exercisesMatched", 3)
        assertCount(app, "hevyImport.preview.newCustoms", 1)
        assertCount(app, "hevyImport.preview.drop.cardio", 1)
        assertCount(app, "hevyImport.preview.drop.rpe", 1)
        assertCount(app, "hevyImport.preview.drop.superset", 2)
        assertCount(app, "hevyImport.preview.drop.setTypeMarkers", 1)
        XCTAssertTrue(scrollTo(app, "hevyImport.preview.encodingOK").exists, "Expected the encoding check to be shown")
        assertCount(app, "hevyImport.preview.drop.unclosedQuote", 0)
        assertCount(app, "hevyImport.preview.drop.malformedRows", 1)
        XCTAssertTrue(
            scrollTo(app, "hevyImport.preview.malformedRow.10").exists,
            "Expected the malformed row to be listed with its row number and reason"
        )
        attachScreenshot(from: app, name: "BurlyPhone-hevyImportPreview")

        // Import -> summary matches the preview.
        let importButton = scrollTo(app, "hevyImport.importButton")
        XCTAssertEqual(importButton.label, "Import 3 Workouts")
        importButton.tap()
        XCTAssertTrue(
            element(app, "hevyImport.summary.heading").waitForExistence(timeout: 30),
            "Expected the import to finish with a complete summary"
        )
        assertCount(app, "hevyImport.summary.workoutsAdded", 3)
        assertCount(app, "hevyImport.summary.alreadyImported", 0)
        assertCount(app, "hevyImport.summary.sets", 7)
        assertCount(app, "hevyImport.summary.newCustoms", 1)
        XCTAssertTrue(
            scrollTo(app, "hevyImport.summary.matchesPreview").exists,
            "Expected the summary to confirm it matches the preview"
        )
        assertCount(app, "hevyImport.summary.drop.cardio", 1)
        attachScreenshot(from: app, name: "BurlyPhone-hevyImportSummary")
        scrollTo(app, "hevyImport.doneButton").tap()

        // History shows the imported workouts immediately.
        let sessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyTab.sessionRow."))
        XCTAssertTrue(
            sessionRows.firstMatch.waitForExistence(timeout: 15),
            "Expected History to show an imported session right after the import"
        )
        XCTAssertEqual(distinctIdentifiers(sessionRows), 3, "Expected exactly the three imported workouts in History")

        // An imported session links no HealthKit workout (§8 acceptance #3).
        sessionRows.firstMatch.tap()
        XCTAssertTrue(
            firstElement(app, identifierPrefix: "historyDetail.revision.").waitForExistence(timeout: 15),
            "Expected the imported session's detail to open"
        )
        XCTAssertFalse(
            firstElement(app, identifierPrefix: "historyDetail.healthKitWorkout.").exists,
            "An imported session must not claim a HealthKit workout"
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Same file again, from Settings: nothing new, nothing duplicated.
        app.tabBars.buttons["Settings"].tap()
        let importRow = element(app, "settingsTab.importRow")
        XCTAssertTrue(importRow.waitForExistence(timeout: 5), "Expected the Settings import row")
        importRow.tap()
        XCTAssertTrue(
            app.buttons["hevyImport.chooseFileButton"].waitForExistence(timeout: 15),
            "Expected the Settings row to open the import screen"
        )
        app.buttons["hevyImport.chooseFileButton"].tap()
        XCTAssertTrue(
            element(app, "hevyImport.preview.nothingNew").waitForExistence(timeout: 15),
            "Expected re-importing the same file to say everything is already in Burly"
        )
        assertCount(app, "hevyImport.preview.newWorkouts", 0)
        assertCount(app, "hevyImport.preview.alreadyImported", 3)
        attachScreenshot(from: app, name: "BurlyPhone-hevyImportNothingNew")
        let done = scrollTo(app, "hevyImport.doneButton")
        XCTAssertTrue(done.exists, "Expected Done where the import action would be")
        XCTAssertFalse(
            element(app, "hevyImport.importButton").exists,
            "Expected no import action when nothing is new"
        )
        done.tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(sessionRows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(distinctIdentifiers(sessionRows), 3, "Expected the re-import to leave History unchanged")
    }

    /// Backing out of the welcome's import lands in the tab shell, and the
    /// welcome does not come back.
    func testCancellingWelcomeImportLandsInTabs() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioEmpty
        app.launchEnvironment[Self.fixtureKey] = Self.fixtureSynthetic
        app.launchArguments += ["-burly-reset-welcome"]
        app.launch()

        XCTAssertTrue(app.staticTexts["welcomeView.heading"].waitForExistence(timeout: 15))
        app.buttons["welcomeView.importButton"].tap()
        let cancel = app.buttons["hevyImport.cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Expected a way out of the import intro")
        cancel.tap()

        XCTAssertTrue(
            app.staticTexts["historyTab.emptyState.heading"].waitForExistence(timeout: 15),
            "Expected cancelling the welcome's import to land on History"
        )
        XCTAssertFalse(app.staticTexts["welcomeView.heading"].exists, "The answered welcome must not return")
    }

    // MARK: - Helpers

    /// Stable identifier, whatever accessibility element type SwiftUI
    /// exposes it as.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// SwiftUI may expose one List row's identifier on both the cell and the
    /// control inside it, so rows are counted by distinct identifier (each
    /// History row's identifier carries its session UUID).
    private func distinctIdentifiers(_ query: XCUIElementQuery) -> Int {
        Set(query.allElementsBoundByIndex.map { $0.identifier }).count
    }

    private func firstElement(_ app: XCUIApplication, identifierPrefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .firstMatch
    }

    /// The preview and summary are lazy Lists: a row further down does not
    /// exist in the hierarchy until it scrolls near the screen. Swipe up a
    /// bounded number of times until it does (and is on screen to tap).
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        let list = app.collectionViews.firstMatch
        var swipes = 0
        while (target.exists == false || target.isHittable == false) && swipes < 15 {
            list.swipeUp()
            swipes += 1
        }
        return target
    }

    private func assertCount(
        _ app: XCUIApplication,
        _ identifier: String,
        _ expected: Int,
        waitForIt: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = element(app, identifier)
        if waitForIt {
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Expected \(identifier)", file: file, line: line)
        }
        let found = scrollTo(app, identifier)
        XCTAssertTrue(found.exists, "Expected \(identifier) on screen", file: file, line: line)
        XCTAssertEqual(found.value as? String, "\(expected)", "\(identifier)", file: file, line: line)
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
