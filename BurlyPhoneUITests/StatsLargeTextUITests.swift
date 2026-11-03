// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import XCTest

/// Stats at the largest accessibility text size (#30, #37, #38), plus the
/// populated scenario's Unattributed muscle-split share (m6-03 carry).
///
/// XCUITest sees controls and legend rows, but not the text Swift Charts
/// draws on its axes, so these tests check what they can measure: each
/// chart grows with the text and fits wholly on screen between the
/// navigation bar and the tab bar, the exercise menu wraps a long name,
/// controls stay inside the screen, and the muscle-split legend rows sit
/// below the donut without overlapping each other. Whether the axis
/// labels themselves read cleanly is judged from the screenshots each test
/// keeps (named `StatsLargeText-*` and `StatsDefaultText-*`).
final class StatsLargeTextUITests: XCTestCase {

    // Repeated from PhoneDemoSeed: the UI-test bundle cannot import the app.
    private static let scenarioKey = "BURLY_PHONE_UI_TEST_SCENARIO"
    private static let scenarioPopulated = "populated"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Largest text

    /// #30: the selected exercise wraps instead of clipping, and the
    /// progression chart grows so its axes have room. Moved here from
    /// draft PR #31, with the chart now required to fit on screen whole.
    @MainActor
    func testLargestTextExerciseMenuWrapsAndProgressionChartFits() throws {
        let app = launchStats(contentSize: .accessibilityExtraExtraExtraLarge)

        let menu = app.buttons["statsTab.progression.exercisePicker"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        scrollFullyIntoView(menu, in: app)
        XCTAssertTrue(menu.isHittable)
        // Back Squat is the seed's latest session's highest-volume lift, so
        // the chart opens there, not on the alphabetically first exercise.
        XCTAssertEqual(menu.value as? String, "Back Squat")
        menu.tap()
        let bench = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Barbell Bench Press")).firstMatch
        XCTAssertTrue(bench.waitForExistence(timeout: 10))
        attachScreenshot(from: app, name: "StatsLargeText-exerciseMenu")
        bench.tap()

        let selectedMenu = app.buttons.matching(identifier: "statsTab.progression.exercisePicker")
            .matching(NSPredicate(format: "value == %@", "Barbell Bench Press")).firstMatch
        XCTAssertTrue(selectedMenu.waitForExistence(timeout: 15))
        scrollFullyIntoView(selectedMenu, in: app)
        XCTAssertGreaterThan(selectedMenu.frame.height, 100, "The long selected title must have space to wrap at largest text")
        assertWithinScreenWidth(selectedMenu, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-exercise")

        let chart = anyElement(app, identifier: "statsTab.progression.chart")
        scrollFullyIntoView(chart, in: app)
        XCTAssertGreaterThan(chart.frame.height, 300, "Plot and axes must grow with text (220 pt at the default size)")
        assertWithinScreenWidth(chart, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-progression")
    }

    /// #37, volume: at 8, 26 and 52 weeks the chart fits on screen whole
    /// and the range control stays inside the screen.
    @MainActor
    func testLargestTextWeeklyVolumeFitsAtEveryRange() throws {
        let app = launchStats(contentSize: .accessibilityExtraExtraExtraLarge)
        XCTAssertTrue(app.buttons["8W"].waitForExistence(timeout: 15))

        for range in ["8W", "26W", "52W"] {
            let segment = app.buttons[range]
            scrollFullyIntoView(segment, in: app)
            segment.tap()
            XCTAssertTrue(waitUntilSelected(segment), "Expected \(range) to become the selected volume range")
            for label in ["8W", "26W", "52W"] {
                assertWithinScreenWidth(app.buttons[label], in: app)
            }

            let chart = anyElement(app, identifier: "statsTab.volume.chart")
            scrollFullyIntoView(chart, in: app)
            XCTAssertGreaterThan(chart.frame.height, 280, "Volume (\(range)) must grow with text (200 pt at the default size)")
            assertWithinScreenWidth(chart, in: app)
            attachScreenshot(from: app, name: "StatsLargeText-volume-\(range)")
        }
    }

    /// #38: one legend, below the donut, one row per slice (Unattributed
    /// included), no row overlapping another.
    @MainActor
    func testLargestTextMuscleSplitHasOneLegendBelowTheDonut() throws {
        let app = launchStats(contentSize: .accessibilityExtraExtraExtraLarge)

        let chart = anyElement(app, identifier: "statsTab.muscleSplit.chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        scrollFullyIntoView(chart, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-muscleSplit-chart")

        let rows = legendRows(in: app)
        XCTAssertGreaterThan(rows.count, 1, "Expected one legend row per populated muscle group")
        let frames = rows.map(\.frame).sorted { $0.minY < $1.minY }
        XCTAssertGreaterThanOrEqual(frames[0].minY, chart.frame.maxY - 0.5, "The legend must start below the donut, not inside it")
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.maxY, lower.minY + 0.5, "Legend rows must not overlap: \(upper) vs \(lower)")
        }
        for row in rows {
            assertWithinScreenWidth(row, in: app)
            XCTAssertFalse(row.label.isEmpty, "Every legend row names its group")
            XCTAssertNotNil(percent(of: row), "Expected a whole percentage on \(row.identifier), got \(String(describing: row.value))")
        }

        let unattributed = anyElement(app, identifier: "statsTab.muscleSplit.legend.unattributed")
        scrollFullyIntoView(unattributed, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-muscleSplit-legend")
        let note = anyElement(app, identifier: "statsTab.muscleSplit.attributionNote")
        scrollFullyIntoView(note, in: app)
        assertWithinScreenWidth(note, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-muscleSplit-note")
    }

    /// #37, consistency: the chart fits on screen whole with its dots.
    @MainActor
    func testLargestTextConsistencyChartFits() throws {
        let app = launchStats(contentSize: .accessibilityExtraExtraExtraLarge)

        let chart = anyElement(app, identifier: "statsTab.consistency.chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        scrollFullyIntoView(chart, in: app)
        XCTAssertGreaterThan(chart.frame.height, 270, "Consistency must grow with text (190 pt at the default size)")
        assertWithinScreenWidth(chart, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-consistency")

        let dots = anyElement(app, identifier: "statsTab.consistency.calendarDots")
        scrollFullyIntoView(dots, in: app)
        assertWithinScreenWidth(dots, in: app)
        attachScreenshot(from: app, name: "StatsLargeText-consistency-dots")
    }

    // MARK: - Default text

    /// m6-03 carry: the populated seed logs exercise-less working sets in
    /// the last four weeks, so the split must show an Unattributed slice
    /// with a non-zero share, and the attribution note must quote the same
    /// share. The other default-size captures are the "unchanged at the
    /// default size" evidence for the large-text changes.
    @MainActor
    func testDefaultTextShowsUnattributedShareAndKeepsChartSizes() throws {
        let app = launchStats(contentSize: nil)

        let chart = anyElement(app, identifier: "statsTab.progression.chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        scrollFullyIntoView(chart, in: app)
        XCTAssertEqual(chart.frame.height, 220, accuracy: 1, "The default-size progression chart keeps its height")
        attachScreenshot(from: app, name: "StatsDefaultText-progression")

        for range in ["8W", "26W", "52W"] {
            let segment = app.buttons[range]
            scrollFullyIntoView(segment, in: app)
            segment.tap()
            XCTAssertTrue(waitUntilSelected(segment), "Expected \(range) to become the selected volume range")
            let volume = anyElement(app, identifier: "statsTab.volume.chart")
            scrollFullyIntoView(volume, in: app)
            XCTAssertEqual(volume.frame.height, 200, accuracy: 1, "The default-size volume chart keeps its height")
            attachScreenshot(from: app, name: "StatsDefaultText-volume-\(range)")
        }

        let unattributed = anyElement(app, identifier: "statsTab.muscleSplit.legend.unattributed")
        XCTAssertTrue(unattributed.waitForExistence(timeout: 5), "Expected an Unattributed row in the muscle-split legend")
        scrollFullyIntoView(anyElement(app, identifier: "statsTab.muscleSplit.chart"), in: app)
        attachScreenshot(from: app, name: "StatsDefaultText-muscleSplit")
        XCTAssertEqual(unattributed.label, "Unattributed")
        let share = try XCTUnwrap(percent(of: unattributed), "Expected a percentage, got \(String(describing: unattributed.value))")
        XCTAssertGreaterThan(share, 0, "The populated seed's exercise-less sets must show as a non-zero share")
        let note = anyElement(app, identifier: "statsTab.muscleSplit.attributionNote")
        XCTAssertTrue(
            note.label.contains("Unattributed work is included (\(share)%)"),
            "The attribution note must quote the legend's share, got: \(note.label)"
        )

        let consistency = anyElement(app, identifier: "statsTab.consistency.chart")
        scrollFullyIntoView(consistency, in: app)
        XCTAssertEqual(consistency.frame.height, 190, accuracy: 1, "The default-size consistency chart keeps its height")
        attachScreenshot(from: app, name: "StatsDefaultText-consistency")
    }

    // MARK: - Helpers

    /// Populated scenario, welcome skipped, Stats open. `nil` leaves the
    /// simulator's own text size alone.
    private func launchStats(contentSize: UIContentSizeCategory?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = Self.scenarioPopulated
        app.launchArguments += ["-burly-skip-welcome"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize.rawValue]
        }
        app.launch()
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 10), "Stats needs its own navigation host")
        return app
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func legendRows(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "statsTab.muscleSplit.legend."))
            .allElementsBoundByIndex
    }

    /// The whole-number percentage a legend row reads out as its value.
    private func percent(of row: XCUIElement) -> Int? {
        guard let value = row.value as? String,
              let match = value.firstMatch(of: /^(\d+)%$/) else { return nil }
        return Int(match.1)
    }

    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)],
            timeout: 10
        ) == .completed
    }

    /// The strip of screen Stats content is readable in: below the
    /// navigation bar and above the tab bar.
    private func visibleBand(in app: XCUIApplication) -> ClosedRange<CGFloat> {
        let navigationBar = app.navigationBars["Stats"]
        let tabBar = app.tabBars.firstMatch
        let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
        let bottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY
        return top...bottom
    }

    /// Drags the Stats scroll view, slowly and without momentum, until
    /// `element` sits wholly inside `visibleBand`. Each drag moves at most
    /// about 40% of the screen, so a tall element is not skipped past.
    private func scrollFullyIntoView(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let height = app.frame.height
        for _ in 0..<30 {
            let band = visibleBand(in: app)
            var offset: CGFloat
            if element.exists {
                let frame = element.frame
                if frame.minY >= band.lowerBound && frame.maxY <= band.upperBound { return }
                guard frame.height <= band.upperBound - band.lowerBound else {
                    XCTFail("\(element.identifier) is \(frame.height) pt tall, taller than the visible \(band)", file: file, line: line)
                    return
                }
                // Positive drags the content up (to reveal what is below).
                offset = frame.maxY > band.upperBound ? frame.maxY - band.upperBound + 12 : -(band.lowerBound - frame.minY + 12)
            } else {
                offset = height * 0.4
            }
            offset = min(max(offset, -height * 0.4), height * 0.4)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5 - offset / height))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Could not scroll \(element.identifier) wholly into view: \(element.frame) vs \(visibleBand(in: app))", file: file, line: line)
    }

    private func assertWithinScreenWidth(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX - 0.5, "\(element.identifier) starts off screen: \(frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX + 0.5, "\(element.identifier) runs off screen: \(frame)", file: file, line: line)
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
