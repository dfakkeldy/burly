// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// What the watch home shows for sync state it got from the phone (spec §5):
/// a snapshot with no routines ends "Waiting for iPhone" and leaves §2's
/// "Empty session" reachable, and an envelope from a newer Burly is surfaced
/// above the routines the watch keeps running, not only on the waiting
/// screen.
///
/// The held schema version reaches the app as a `-key value` launch
/// argument, which lands in the app's `UserDefaults` argument domain: the
/// same key `WatchSyncHost` writes and the home views read with
/// `@AppStorage`. Seeded scenarios run without a sync host, so nothing in
/// the app clears or overwrites it.
final class WatchSyncStateUITests: XCTestCase {
    private static let scenarioKey = "BURLY_WATCH_UI_TEST_SCENARIO"
    /// Matched literally against `WatchSyncHost.heldSchemaVersionDefaultsKey`.
    private static let heldSchemaVersionKey = "burly.sync.heldSchemaVersion"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// §5: the snapshot, not a routine, unlocks the list. A phone with no
    /// routines yet still lets the lifter start an empty session.
    func testSnapshotWithNoRoutinesOffersEmptySession() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "syncedNoRoutines"
        app.launch()

        let hint = app.staticTexts["routineList.emptyHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 15), "Expected the no-routines hint on the routine list")
        XCTAssertFalse(
            app.staticTexts["waitingForPhoneView.headline"].exists,
            "An applied snapshot must end 'Waiting for iPhone'"
        )
        let emptySession = anyElement(app, identifier: "emptySessionRow")
        XCTAssertTrue(emptySession.exists, "Expected §2's 'Empty session' with no routines")

        attachScreenshot(from: app, name: "BurlyWatch-noRoutines")

        emptySession.tap()
        XCTAssertTrue(
            app.buttons["emptySession.addExercise"].waitForExistence(timeout: 10),
            "Expected 'Empty session' to open the empty logging screen"
        )
    }

    /// §5: a held envelope is surfaced while the watch keeps its routines.
    func testHeldSchemaShowsUpdateNoticeAboveRoutines() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launchArguments += ["-\(Self.heldSchemaVersionKey)", "99"]
        app.launch()

        let notice = app.staticTexts["routineList.updateNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "Expected the update notice on the routine list")
        XCTAssertTrue(notice.label.contains("Update Burly on Apple Watch"))
        XCTAssertTrue(
            app.staticTexts["routineRow.Leg Day.name"].exists,
            "The routines the watch can read stay usable"
        )
        XCTAssertFalse(app.staticTexts["routineList.emptyHint"].exists)

        attachScreenshot(from: app, name: "BurlyWatch-updateNotice")
    }

    /// Without a held envelope the list shows no notice.
    func testNoUpdateNoticeWithoutHeldSchema() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "routines"
        app.launch()

        XCTAssertTrue(app.staticTexts["routineRow.Leg Day.name"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["routineList.updateNotice"].exists)
    }

    /// The waiting screen reads the same held version, so the notice
    /// survives a relaunch before the phone pushes again.
    func testHeldSchemaOnWaitingScreenSaysUpdate() throws {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = "empty"
        app.launchArguments += ["-\(Self.heldSchemaVersionKey)", "99"]
        app.launch()

        let detail = app.staticTexts["waitingForPhoneView.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "Expected the waiting screen")
        XCTAssertTrue(detail.label.contains("Update Burly on Apple Watch"))
    }

    /// Matches any element type: a `NavigationLink` row can surface as a
    /// button or a cell depending on the watchOS release.
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
