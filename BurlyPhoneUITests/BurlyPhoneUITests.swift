// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

final class BurlyPhoneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches BurlyPhone and asserts it reaches its placeholder UI.
    /// Uses an accessibility-tree wait (waitForExistence), never a fixed sleep,
    /// so the assertion is driven by actual UI state rather than a timing guess.
    func testAppLaunchesToPlaceholderUI() throws {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["Burly"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 15),
            "Expected the 'Burly' placeholder title to appear after launch"
        )

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "BurlyPhone-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
