// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Exercises the phone Settings tab (spec §9 Phone IA Settings bullet,
/// planning task m5-05) and spec §9 acceptance #2: "Unit toggle: stored kg
/// values render correctly in lb everywhere (spot-asserted in history,
/// editor, stats)."
///
/// The editor half covers the input path as well as rendering. A unit
/// toggle that only relabels the weight field still passes every render
/// assertion while storing 180 kg for a lifter who typed 180 in lb mode, so
/// `testPoundsEntryStoresConvertedKilograms` types in lb, switches back to
/// kg, and asserts the converted kg value that was actually stored.
///
/// Determinism: every launch here carries the UI-test scenario key, and
/// BurlyPhone (DEBUG only) resets the display-unit preference to kg on any
/// such launch unless `-burly-keep-display-unit` is passed. A test that
/// switches to lb therefore cannot leak pounds into the next test, or into
/// BurlyPhoneUITests, which asserts kg strings like "82.5 kg × 12".
///
/// Scenario keys, seeded ids and the small helpers below are copied from
/// BurlyPhoneUITests.swift rather than shared: that file is owned by the
/// shell suite, and the UI-test bundle cannot import the app target
/// (PhoneDemoSeed.SeededIDs is the source of the ids).
///
/// `@MainActor` because XCUIElement / XCUIApplication are main-actor
/// isolated in the iOS 26 SDK; the test runner already calls tests on the
/// main thread, so this only makes the isolation explicit.
@MainActor
final class SettingsUITests: XCTestCase {

    private static let scenarioKey = "BURLY_PHONE_UI_TEST_SCENARIO"
    private static let scenarioEmpty = "empty"
    private static let scenarioPopulated = "populated"
    private static let keepUnitArgument = "-burly-keep-display-unit"

    private static let loggedSessionID = "6F4E2C1A-0000-4000-8000-000000000003"
    private static let squatWorkingSetID = "6F4E2C1A-0000-4000-8000-000000000006"

    // Expected strings, derived from PhoneDemoSeed's populated acceptance
    // session (progressionIndex 12): squat 90 kg (30 kg warmup), bench
    // 55 kg, a bodyweight pull-up, and a 20 kg × 12 unattributed set.
    //
    // Working volume: 90×5 + 90×8 + 55×8 + 55×10 + 0×8 + 20×12 = 2400 kg,
    // = 5291.09… lb.
    private static let volumeKg = "2400 kg"
    private static let volumeLb = "5291 lb"
    // Squat working set: 90 kg × 5 = 198.416… lb × 5.
    private static let squatWorkingSetKg = "90.0 kg × 5"
    private static let squatWorkingSetLb = "198.4 lb × 5"
    // Best in the default 3-month range: top set 90 kg; estimated 1RM by
    // Epley on 90 kg × 8 = 114 kg = 251.327… lb.
    private static let statsTopSetKg = "90.0 kg"
    private static let statsEstimateKg = "114.0 kg"
    private static let statsTopSetLb = "198.4 lb"
    private static let statsEstimateLb = "251.3 lb"

    override nonisolated func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Rows

    /// Every Settings row is present and honest: the unit choice defaults
    /// to kg on a reset launch, the rest default reads as the §3 90 s
    /// default, the HealthKit row is informational with an Open Health
    /// action, Import leads to its screen, and About carries the version,
    /// the source-code link, and a Licenses screen with the full text.
    func testSettingsRowsAndLicensesScreen() throws {
        let app = launch(scenario: Self.scenarioEmpty)
        openSettings(in: app)

        XCTAssertTrue(
            anyElement(app, identifier: "settingsTab.unitOption.kg").waitForExistence(timeout: 5),
            "Expected the kilograms option"
        )
        XCTAssertTrue(anyElement(app, identifier: "settingsTab.unitOption.kg").isSelected, "Expected kg to be the reset default")
        XCTAssertFalse(anyElement(app, identifier: "settingsTab.unitOption.lb").isSelected, "Expected lb not to be selected")

        let restRow = scrollToElement(app, identifier: "settingsTab.restDefaultRow")
        XCTAssertTrue(
            accessibleText(of: restRow).contains("1:30"),
            "Expected the read-only rest default to show the 90 s global default as 1:30, got \(accessibleText(of: restRow))"
        )

        XCTAssertTrue(scrollToElement(app, identifier: "settingsTab.healthRow").exists, "Expected the Apple Health row")
        // Not tapped: it leaves the app for Health (or Settings).
        XCTAssertTrue(scrollToElement(app, identifier: "settingsTab.openHealth").exists, "Expected the Open Health action")

        XCTAssertTrue(scrollToElement(app, identifier: "settingsTab.versionRow").exists, "Expected the version row")
        // Not tapped: it leaves the app for the browser.
        XCTAssertTrue(scrollToElement(app, identifier: "settingsTab.sourceCodeLink").exists, "Expected the source code link")

        scrollToElement(app, identifier: "settingsTab.licensesRow").tap()
        XCTAssertTrue(
            anyElement(app, identifier: "licenses.summary").waitForExistence(timeout: 5),
            "Expected the plain-language summary at the top of Licenses"
        )
        XCTAssertTrue(scrollToElement(app, identifier: "licenses.exceptionHeading").exists, "Expected the App Store exception section")
        XCTAssertFalse(anyElement(app, identifier: "licenses.exception.unavailable").exists, "Expected the bundled exception text to load")
        XCTAssertTrue(
            scrollToElement(app, labelContaining: "Distribute through Apple").exists,
            "Expected the exception's own text, read from the bundled file"
        )
        XCTAssertTrue(scrollToElement(app, identifier: "licenses.gplHeading").exists, "Expected the GPL section")
        XCTAssertTrue(
            scrollToElement(app, labelContaining: "GNU GENERAL PUBLIC LICENSE").exists,
            "Expected the GPL text, read from the bundled LICENSE file"
        )
        XCTAssertFalse(anyElement(app, identifier: "licenses.gpl.unavailable").exists, "Expected the bundled GPL text to load")
        attachScreenshot(from: app, name: "BurlyPhone-licenses")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        scrollUpToElement(app, identifier: "settingsTab.importRow").tap()
        XCTAssertTrue(
            app.staticTexts["hevyImport.intro.heading"].waitForExistence(timeout: 5),
            "Expected the Import row to open the import screen"
        )
    }

    // MARK: - §9 #2 render path

    /// Stored kg values render in lb in History (session volume), the
    /// session detail's set rows, and Stats — and switching back re-renders
    /// kg without a relaunch.
    func testPoundsRenderInHistoryDetailAndStats() throws {
        let app = launch(scenario: Self.scenarioPopulated)

        let sessionRow = anyElement(app, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 15), "Expected the seeded session in History")
        // Baseline: the reset launch renders kg, so the lb assertions below
        // prove a conversion rather than a fixture that was already lb.
        XCTAssertTrue(contains(sessionRow, Self.volumeKg), "Expected kg volume before switching, got \(accessibleText(of: sessionRow))")

        selectUnit("lb", in: app)

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 5))
        XCTAssertTrue(contains(sessionRow, Self.volumeLb), "Expected History volume in lb, got \(accessibleText(of: sessionRow))")
        XCTAssertFalse(contains(sessionRow, " kg"), "Expected no kg left in the History row")

        sessionRow.tap()
        XCTAssertTrue(
            anyElement(app, identifier: "historyDetail.set.\(Self.squatWorkingSetID)").waitForExistence(timeout: 5),
            "Expected the seeded squat working set row"
        )
        XCTAssertTrue(
            app.staticTexts[Self.squatWorkingSetLb].waitForExistence(timeout: 5),
            "Expected the squat working set to render as \(Self.squatWorkingSetLb)"
        )
        XCTAssertFalse(app.staticTexts[Self.squatWorkingSetKg].exists, "Expected no kg set row while in lb")

        app.tabBars.buttons["Stats"].tap()
        let summary = anyElement(app, identifier: "statsTab.progression.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Expected the progression summary under the chart")
        let poundsSummary = accessibleText(of: summary)
        XCTAssertTrue(poundsSummary.contains(Self.statsTopSetLb), "Expected the best top set in lb, got \(poundsSummary)")
        XCTAssertTrue(poundsSummary.contains(Self.statsEstimateLb), "Expected the best estimated 1RM in lb, got \(poundsSummary)")
        XCTAssertFalse(poundsSummary.contains("kg"), "Expected no kg in the lb stats summary, got \(poundsSummary)")
        attachScreenshot(from: app, name: "BurlyPhone-statsPounds")

        // And back: the same screens re-render kg live.
        selectUnit("kg", in: app)
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let kilogramSummary = accessibleText(of: summary)
        XCTAssertTrue(kilogramSummary.contains(Self.statsTopSetKg), "Expected the best top set back in kg, got \(kilogramSummary)")
        XCTAssertTrue(kilogramSummary.contains(Self.statsEstimateKg), "Expected the best estimated 1RM back in kg, got \(kilogramSummary)")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts[Self.squatWorkingSetKg].waitForExistence(timeout: 5),
            "Expected the still-open session detail to re-render the set in kg"
        )
    }

    // MARK: - §9 #2 input path

    /// Typing 180 in lb mode stores 180 lb (81.6466… kg), not 180 kg. The
    /// stored value is observed by switching back to kg: the broken
    /// relabel-only toggle would render "180.0 kg × 5" here.
    func testPoundsEntryStoresConvertedKilograms() throws {
        let app = launch(scenario: Self.scenarioPopulated)
        selectUnit("lb", in: app)

        app.tabBars.buttons["History"].tap()
        let sessionRow = anyElement(app, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 15), "Expected the seeded session in History")
        sessionRow.tap()

        anyElement(app, identifier: "historyDetail.set.\(Self.squatWorkingSetID)").tap()
        let weightField = app.textFields["historyDetail.setWeight"]
        XCTAssertTrue(weightField.waitForExistence(timeout: 5), "Expected the set editor's weight field")
        // The field speaks the display unit in both directions: its title
        // names lb and its starting text is the stored 90 kg in lb.
        XCTAssertTrue(
            weightField.label.contains("lb") || (weightField.placeholderValue ?? "").contains("lb"),
            "Expected the weight field to be labeled in lb, got label \(weightField.label) placeholder \(weightField.placeholderValue ?? "nil")"
        )
        XCTAssertEqual(editableContents(of: weightField), "198.4", "Expected the editor to start from the stored weight in lb")

        replaceText(in: weightField, with: "180", app: app)
        app.buttons["historyDetail.saveSet"].tap()
        XCTAssertTrue(
            app.staticTexts["180.0 lb × 5"].waitForExistence(timeout: 5),
            "Expected the saved set to render as entered, 180.0 lb × 5"
        )

        // The detail stays pushed in the History tab while the unit changes.
        selectUnit("kg", in: app)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts["81.6 kg × 5"].waitForExistence(timeout: 5),
            "Expected 180 lb to have been stored as 81.6466… kg"
        )
        XCTAssertFalse(
            app.staticTexts["180.0 kg × 5"].exists,
            "180 typed in lb mode must not be stored as 180 kg"
        )

        // The kg editor now starts from the converted value.
        anyElement(app, identifier: "historyDetail.set.\(Self.squatWorkingSetID)").tap()
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        XCTAssertEqual(editableContents(of: weightField), "81.6", "Expected the kg editor to start from the stored kg")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // And the stored value converts back to exactly what was typed.
        selectUnit("lb", in: app)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts["180.0 lb × 5"].waitForExistence(timeout: 5),
            "Expected the stored kg to convert back to exactly 180.0 lb"
        )
        attachScreenshot(from: app, name: "BurlyPhone-poundsEntry")
    }

    // MARK: - Persistence and test isolation

    /// The unit choice persists across a real relaunch, and a UI-test
    /// launch without the keep argument starts from kg again — the seam
    /// that keeps this suite from leaking lb into others.
    func testUnitChoicePersistsAcrossRelaunchAndTestLaunchesReset() throws {
        let app = launch(scenario: Self.scenarioPopulated)
        selectUnit("lb", in: app)
        app.terminate()

        let relaunched = launch(scenario: Self.scenarioPopulated, keepingUnit: true)
        let sessionRow = anyElement(relaunched, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 15), "Expected the seeded session in History")
        XCTAssertTrue(contains(sessionRow, Self.volumeLb), "Expected lb to persist across relaunch, got \(accessibleText(of: sessionRow))")
        openSettings(in: relaunched)
        XCTAssertTrue(
            anyElement(relaunched, identifier: "settingsTab.unitOption.lb").waitForExistence(timeout: 5)
        )
        XCTAssertTrue(anyElement(relaunched, identifier: "settingsTab.unitOption.lb").isSelected, "Expected lb to stay selected")
        relaunched.terminate()

        let reset = launch(scenario: Self.scenarioPopulated)
        let resetRow = anyElement(reset, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(resetRow.waitForExistence(timeout: 15), "Expected the seeded session in History")
        XCTAssertTrue(contains(resetRow, Self.volumeKg), "Expected a UI-test launch to reset to kg, got \(accessibleText(of: resetRow))")
    }

    // MARK: - Helpers

    private func launch(scenario: String, keepingUnit: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = scenario
        app.launchArguments += ["-burly-skip-welcome"]
        if keepingUnit {
            app.launchArguments += [Self.keepUnitArgument]
        }
        app.launch()
        return app
    }

    /// Tab bar buttons are selected by their spec'd titles: iOS 26's iPhone
    /// UITabBarButton ignores accessibilityIdentifier (see
    /// BurlyPhoneUITests' class doc).
    private func openSettings(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Expected the Settings tab")
        settings.tap()
    }

    /// Chooses a display unit in Settings and waits for the selection to
    /// land, so the next screen is asserted against the new unit. Waits on a
    /// query rather than a predicate expectation: on CI one accessibility
    /// snapshot took over 4 s, so a 5 s expectation got a single look and
    /// failed although the checkmark had moved. waitForExistence polls and
    /// checks once more at its deadline. One tap only, so a tap that really
    /// doesn't select still fails.
    private func selectUnit(_ rawValue: String, in app: XCUIApplication) {
        openSettings(in: app)
        let identifier = "settingsTab.unitOption.\(rawValue)"
        let option = scrollUpToElement(app, identifier: identifier)
        XCTAssertTrue(option.exists, "Expected the \(rawValue) option in Settings")
        option.tap()
        let selectedOption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND selected == true", identifier))
            .firstMatch
        XCTAssertTrue(
            selectedOption.waitForExistence(timeout: 15),
            "Expected \(rawValue) to become selected after tapping it"
        )
    }

    /// Looks a stable identifier up regardless of the accessibility element
    /// type SwiftUI happens to expose it as.
    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elementWithLabel(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// A combined row may expose its text as one label, a label plus value,
    /// or as child elements; this reads all three.
    private func accessibleText(of element: XCUIElement) -> String {
        var parts = [element.label]
        if let value = element.value as? String, !value.isEmpty { parts.append(value) }
        let children = element.descendants(matching: .staticText)
        for index in 0..<min(children.count, 12) {
            parts.append(children.element(boundBy: index).label)
        }
        return parts.joined(separator: " ")
    }

    private func contains(_ element: XCUIElement, _ text: String) -> Bool {
        accessibleText(of: element).contains(text)
    }

    /// Lazy lists only materialize rows near the viewport; swipe until the
    /// row exists.
    @discardableResult
    private func scrollToElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        scroll(app, toward: anyElement(app, identifier: identifier), description: identifier)
    }

    @discardableResult
    private func scrollToElement(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        scroll(app, toward: elementWithLabel(app, containing: text), description: text)
    }

    /// Slow swipes carry no momentum, so a row that is only partly on
    /// screen (present but not yet hittable) is nudged into view rather than
    /// flung past the top. If the downward pass still misses — say a long
    /// Licenses paragraph overshot — a bounded upward-content pass looks
    /// back before failing (review finding: the helper only ever swiped up).
    private func scroll(_ app: XCUIApplication, toward element: XCUIElement, description: String) -> XCUIElement {
        let maxSwipes = 40
        for swipeCount in 0...maxSwipes {
            if element.waitForExistence(timeout: 1), element.isHittable {
                return element
            }
            guard swipeCount < maxSwipes else { break }
            app.swipeUp(velocity: .slow)
        }
        let maxBackSwipes = 5
        for _ in 0..<maxBackSwipes {
            app.swipeDown(velocity: .slow)
            if element.waitForExistence(timeout: 1), element.isHittable {
                return element
            }
        }
        XCTFail("Expected \(description) after \(maxSwipes) upward and \(maxBackSwipes) downward swipes")
        return element
    }

    /// Mirror of `scrollToElement` for rows near the top of a lazy list.
    private func scrollUpToElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let maxSwipes = 20
        let element = anyElement(app, identifier: identifier)
        if element.waitForExistence(timeout: 5), element.isHittable { return element }
        for _ in 0..<maxSwipes {
            app.swipeDown()
            if element.waitForExistence(timeout: 1), element.isHittable { return element }
        }
        return element
    }

    /// Same approach as BurlyPhoneUITests' helper (see its doc for the CI
    /// history): tap the trailing interior of the Form text field, then
    /// type through the application, and assert the replacement landed.
    private func replaceText(in field: XCUIElement, with value: String, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Expected editable text field")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        let existing = editableContents(of: field)
        if !existing.isEmpty {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        app.typeText(value)

        XCTAssertEqual(
            editableContents(of: field),
            value,
            "Expected field \(field.identifier) to hold \(value) after replacement"
        )
    }

    private func editableContents(of field: XCUIElement) -> String {
        let raw = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if raw.isEmpty || raw == placeholder { return "" }
        return raw
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
