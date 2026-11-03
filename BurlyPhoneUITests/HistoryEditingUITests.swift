// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// History completeness on the phone (spec §1 deletion rule, §6 history
/// surface and naming queue, §9 custom tags): deleting a logged session,
/// the honest message about its Apple Health copy, exercise reorder, saves
/// that change nothing, removing an exercise only after a confirmation,
/// searchable pickers, the naming queue collecting muscle tags, and the
/// catalog retagging an untagged custom exercise.
///
/// No launch here reaches HealthKit. Every UI-test scenario gets a scripted
/// Health remover (BurlyPhone/HistoryWorkoutHealthCleanup.swift), and
/// `BURLY_PHONE_UI_TEST_HEALTH_REMOVAL` picks what it reports; unset, the
/// Health copy could not be removed, so History must say so.
///
/// Scenario keys and seeded ids are copied from BurlyPhoneUITests.swift
/// and PhoneDemoSeed.SeededIDs, as SettingsUITests does: the UI-test bundle
/// cannot import the app target.
///
/// `@MainActor` because XCUIElement / XCUIApplication are main-actor
/// isolated in the iOS 26 SDK.
@MainActor
final class HistoryEditingUITests: XCTestCase {

    private static let scenarioKey = "BURLY_PHONE_UI_TEST_SCENARIO"
    private static let healthRemovalKey = "BURLY_PHONE_UI_TEST_HEALTH_REMOVAL"

    private static let loggedSessionID = "6F4E2C1A-0000-4000-8000-000000000003"
    private static let squatItemID = "6F4E2C1A-0000-4000-8000-000000000004"
    private static let squatWorkingSetID = "6F4E2C1A-0000-4000-8000-000000000006"
    private static let addableExerciseID = "6F4E2C1A-0000-4000-8000-00000000000A"
    private static let placeholderSessionID = "6F4E2C1A-0000-4000-8000-00000000000D"
    private static let firstPlaceholderID = "6F4E2C1A-0000-4000-8000-00000000000E"
    private static let secondPlaceholderID = "6F4E2C1A-0000-4000-8000-00000000000F"
    private static let backSquatExerciseID = "10000000-0000-4000-8000-000000000063"
    private static let benchPressExerciseID = "10000000-0000-4000-8000-000000000001"

    override nonisolated func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Delete

    /// The detail screen's delete asks first, says the Health copy will be
    /// asked for too, removes the session from History, and — because the
    /// scripted Health remover reports a failure — tells the user to finish
    /// the job in the Health app instead of implying it worked.
    func testDetailDeleteRemovesSessionAndSaysHealthCopyRemains() throws {
        let app = launch(scenario: "populated")
        openSession(Self.loggedSessionID, in: app)

        scrollToElement(app, identifier: "historyDetail.deleteSession").tap()
        let confirm = app.buttons.matching(identifier: "historyDetail.confirmDeleteSession").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a workout must ask first")
        XCTAssertTrue(
            staticText(containing: "Apple Health", in: app).exists,
            "The confirmation must say what happens to the linked Health workout"
        )
        attachScreenshot(from: app, name: "BurlyPhone-deleteConfirmation")
        confirm.tap()

        XCTAssertTrue(
            anyElement(app, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)").waitForNonExistence(timeout: 10),
            "The deleted session must leave History"
        )
        let notice = anyElement(app, identifier: "historyTab.notice.message.\(Self.loggedSessionID)")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "A Health copy that was not removed must be reported")
        XCTAssertTrue(notice.label.contains("Health app"), "The report must say how to remove it by hand: \(notice.label)")
        XCTAssertTrue(
            anyElement(app, identifier: "historyTab.notice.title.\(Self.loggedSessionID)").label.contains("Leg Day"),
            "The report must name the workout it is about"
        )
        attachScreenshot(from: app, name: "BurlyPhone-deleteHealthNotice")
        anyElement(app, identifier: "historyTab.notice.dismiss.\(Self.loggedSessionID)").tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
    }

    /// The History row's swipe asks first and a cancelled confirmation keeps
    /// the session. A confirmed delete removes it; when Health reports the
    /// linked workout removed, no second dialog appears. An unlinked session's
    /// confirmation does not mention Health at all.
    func testSwipeDeleteAsksFirstAndAQuietHealthSuccess() throws {
        let app = launch(scenario: "populated", healthRemoval: "removed")
        let linkedRow = anyElement(app, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(linkedRow.waitForExistence(timeout: 15))

        swipeToDelete(linkedRow, sessionID: Self.loggedSessionID, in: app)
        XCTAssertTrue(app.buttons.matching(identifier: "historyTab.confirmDeleteSession").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(staticText(containing: "Apple Health", in: app).exists)
        dismissDialog(in: app)
        XCTAssertTrue(
            app.buttons.matching(identifier: "historyTab.confirmDeleteSession").firstMatch.waitForNonExistence(timeout: 5),
            "The confirmation must close without deleting"
        )
        XCTAssertTrue(linkedRow.waitForExistence(timeout: 5), "Cancelling must keep the session")

        swipeToDelete(linkedRow, sessionID: Self.loggedSessionID, in: app)
        let confirm = app.buttons.matching(identifier: "historyTab.confirmDeleteSession").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(linkedRow.waitForNonExistence(timeout: 10), "The confirmed delete must remove the row")
        XCTAssertFalse(
            firstElement(app, identifierPrefix: "historyTab.notice.message.").waitForExistence(timeout: 3),
            "A removed Health copy needs no second message"
        )

        // The rest of the seed is unlinked (no HealthKit workout).
        let unlinkedRow = firstElement(app, identifierPrefix: "historyTab.sessionRow.")
        XCTAssertTrue(unlinkedRow.waitForExistence(timeout: 5))
        let unlinkedID = try XCTUnwrap(identifierSuffix(of: unlinkedRow, prefix: "historyTab.sessionRow."))
        XCTAssertNotEqual(unlinkedID, Self.loggedSessionID)
        swipeToDelete(unlinkedRow, sessionID: unlinkedID, in: app)
        let confirmUnlinked = app.buttons.matching(identifier: "historyTab.confirmDeleteSession").firstMatch
        XCTAssertTrue(confirmUnlinked.waitForExistence(timeout: 5))
        XCTAssertFalse(staticText(containing: "Apple Health", in: app).exists, "An unlinked session has no Health copy to mention")
        confirmUnlinked.tap()
        XCTAssertTrue(
            anyElement(app, identifier: "historyTab.sessionRow.\(unlinkedID)").waitForNonExistence(timeout: 10)
        )
        XCTAssertFalse(firstElement(app, identifierPrefix: "historyTab.notice.message.").waitForExistence(timeout: 2))
    }

    // MARK: - Detail edits

    /// §6 "reorder": an exercise moves with its header button, the move is a
    /// real edit (one revision), and the first item cannot move further up.
    func testExerciseMoveButtonsReorderAndBumpRevision() throws {
        let app = launch(scenario: "populated")
        openSession(Self.loggedSessionID, in: app)
        assertRevision(1, in: app)

        let squatUp = app.buttons["historyDetail.moveExerciseUp.\(Self.squatItemID)"]
        XCTAssertTrue(squatUp.waitForExistence(timeout: 5))
        XCTAssertFalse(squatUp.isEnabled, "The first exercise cannot move up")

        app.buttons["historyDetail.moveExerciseDown.\(Self.squatItemID)"].tap()
        assertRevision(2, in: app)

        let squat = app.staticTexts["historyDetail.exercise.\(Self.backSquatExerciseID)"]
        let bench = app.staticTexts["historyDetail.exercise.\(Self.benchPressExerciseID)"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        XCTAssertLessThan(bench.frame.minY, squat.frame.minY, "Bench must now come before squat")
        XCTAssertTrue(squatUp.isEnabled, "Squat is second now, so it can move back up")
        attachScreenshot(from: app, name: "BurlyPhone-exerciseReorder")
    }

    /// §6 provenance honesty: opening a set and saving it untouched, or
    /// tapping nothing on notes, is not an edit. The revision stays at 1 and
    /// the History row carries no "Edited" mark until a real edit happens.
    func testSavesThatChangeNothingDoNotMarkTheSessionEdited() throws {
        let app = launch(scenario: "populated")
        let row = anyElement(app, identifier: "historyTab.sessionRow.\(Self.loggedSessionID)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertFalse(row.label.contains("Edited"), "Precondition: the seeded session is unedited")
        row.tap()

        anyElement(app, identifier: "historyDetail.set.\(Self.squatWorkingSetID)").tap()
        let save = app.buttons["historyDetail.saveSet"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "An untouched save still closes the editor")
        assertRevision(1, in: app)
        XCTAssertFalse(anyElement(app, identifier: "historyDetail.revision.2").exists)

        let saveNotes = scrollToElement(app, identifier: "historyDetail.saveNotes")
        XCTAssertFalse(saveNotes.isEnabled, "Unchanged notes have nothing to save")

        goBack(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Edited"), "A save that changed nothing must not mark the session edited")

        // Positive control: a real change does mark it, so the check above
        // is not passing on a label that never says "Edited".
        row.tap()
        anyElement(app, identifier: "historyDetail.set.\(Self.squatWorkingSetID)").tap()
        replaceText(in: app.textFields["historyDetail.setReps"], with: "6", app: app)
        app.buttons["historyDetail.saveSet"].tap()
        assertRevision(2, in: app)
        goBack(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Edited"), "A real edit marks the row: \(row.label)")
    }

    /// Removing an exercise drops all its sets, so it asks first; cancelling
    /// changes nothing, confirming removes it in one revision.
    func testRemovingAnExerciseAsksFirst() throws {
        let app = launch(scenario: "populated")
        openSession(Self.loggedSessionID, in: app)

        let remove = app.buttons["historyDetail.removeExercise.\(Self.benchPressExerciseID)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.buttons.matching(identifier: "historyDetail.confirmRemoveExercise").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Removing an exercise must ask first")
        XCTAssertTrue(staticText(containing: "2 sets", in: app).exists, "The confirmation must say how many sets go with it")
        dismissDialog(in: app)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "The confirmation must close without removing")
        assertRevision(1, in: app)
        XCTAssertTrue(app.staticTexts["historyDetail.exercise.\(Self.benchPressExerciseID)"].exists, "Cancel must keep the exercise")

        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        assertRevision(2, in: app)
        XCTAssertTrue(app.staticTexts["historyDetail.exercise.\(Self.benchPressExerciseID)"].waitForNonExistence(timeout: 5))
    }

    /// The add-exercise picker lists the whole catalog, so it is searchable.
    func testAddExercisePickerIsSearchable() throws {
        let app = launch(scenario: "populated")
        openSession(Self.loggedSessionID, in: app)

        app.buttons["historyDetail.addExercise"].tap()
        let search = app.searchFields["Search exercises"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("UI Test Added")
        let match = app.buttons["historyDetail.exercisePicker.\(Self.addableExerciseID)"]
        XCTAssertTrue(match.waitForExistence(timeout: 5), "Search must surface the exercise by name")
        XCTAssertFalse(app.buttons["historyDetail.exercisePicker.\(Self.benchPressExerciseID)"].exists, "Search must narrow the list")
        match.tap()
        assertRevision(2, in: app)
    }

    // MARK: - Naming queue

    /// §6 naming queue, both resolutions. Naming collects muscle tags (Save
    /// waits for one) and closes; the second placeholder then opens with its
    /// own fresh state, and the merge list leaves out unnamed placeholders.
    /// Merging asks first, closes, and History shows both results.
    func testNamingQueueNamesWithTagsThenMerges() throws {
        let app = launch(scenario: "namingQueue")
        let banner = anyElement(app, identifier: "historyTab.namingQueueBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        banner.tap()

        // Unnamed placeholders are not merge targets: searching their shared
        // name finds neither.
        let search = app.searchFields["Search exercises to merge into"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Custom")
        XCTAssertFalse(app.buttons["namingQueue.merge.\(Self.firstPlaceholderID)"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["namingQueue.merge.\(Self.secondPlaceholderID)"].exists)
        closeSearch(in: app)

        let nameField = app.textFields["namingQueue.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        replaceText(in: nameField, with: "Cable Fly", app: app)
        let saveName = app.buttons["namingQueue.saveName"]
        XCTAssertFalse(saveName.isEnabled, "A name without muscle groups would stay unattributed in Stats")
        app.buttons["namingQueue.muscleTag.chest"].tap()
        XCTAssertEqual(app.buttons["namingQueue.muscleTag.chest"].value as? String, "Selected")
        XCTAssertTrue(saveName.isEnabled)
        saveName.tap()

        // Back on History, the banner now offers the second placeholder,
        // with its own name rather than the one just typed.
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Custom exercise", "The next placeholder must open with fresh state")

        let mergeSearch = app.searchFields["Search exercises to merge into"]
        mergeSearch.tap()
        mergeSearch.typeText("Barbell Bench")
        let benchTarget = app.buttons["namingQueue.merge.\(Self.benchPressExerciseID)"]
        XCTAssertTrue(benchTarget.waitForExistence(timeout: 5))
        benchTarget.tap()
        let confirmMerge = app.buttons.matching(identifier: "namingQueue.confirmMerge").firstMatch
        XCTAssertTrue(confirmMerge.waitForExistence(timeout: 5), "Merging rewrites history, so it asks first")
        confirmMerge.tap()

        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Both placeholders are resolved")
        openSession(Self.placeholderSessionID, in: app)
        let firstHeader = app.staticTexts["historyDetail.exercise.\(Self.firstPlaceholderID)"]
        let secondHeader = app.staticTexts["historyDetail.exercise.\(Self.secondPlaceholderID)"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 5) || secondHeader.exists)
        XCTAssertNotEqual(firstHeader.exists, secondHeader.exists, "One placeholder was named, the other merged away")
        let named = firstHeader.exists ? firstHeader : secondHeader
        XCTAssertEqual(named.label, "Cable Fly")
        let merged = app.staticTexts["historyDetail.exercise.\(Self.benchPressExerciseID)"]
        XCTAssertTrue(merged.exists, "The merged item now names the destination")
        XCTAssertEqual(merged.label, "Barbell Bench Press")
        attachScreenshot(from: app, name: "BurlyPhone-namingQueueResolved")
    }

    // MARK: - Catalog tags

    /// A custom exercise with no muscle groups (a Hevy import's unmatched
    /// custom has the same shape) can be tagged from the catalog; curated
    /// exercises offer no tag editor.
    func testCatalogRetagsAnUntaggedCustomExercise() throws {
        let app = launch(scenario: "populated")
        app.tabBars.buttons["Routines"].tap()
        let catalogButton = app.buttons["routinesTab.catalogButton"]
        XCTAssertTrue(catalogButton.waitForExistence(timeout: 10))
        catalogButton.tap()

        let search = app.searchFields["Search exercises"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Back Squat")
        XCTAssertTrue(app.buttons["catalog.archiveExercise.\(Self.backSquatExerciseID)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["catalog.editTags.\(Self.backSquatExerciseID)"].exists, "Curated tags are catalog truth")

        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Back Squat".count))
        search.typeText("UI Test Added")
        let tags = app.staticTexts["catalog.exerciseTags.\(Self.addableExerciseID)"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5))
        XCTAssertEqual(tags.label, "No muscle groups")

        app.buttons["catalog.editTags.\(Self.addableExerciseID)"].tap()
        let save = app.buttons["catalog.editTags.saveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "At least one muscle group is required")
        app.buttons["catalog.editTags.muscleTag.chest"].tap()
        app.buttons["catalog.editTags.muscleTag.triceps"].tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        let retagged = NSPredicate(format: "label == %@", "Chest · Triceps")
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: retagged, object: tags)], timeout: 5),
            .completed,
            "The catalog must show the saved tags, got: \(tags.label)"
        )
        attachScreenshot(from: app, name: "BurlyPhone-catalogRetag")
    }

    // MARK: - Helpers

    private func launch(scenario: String, healthRemoval: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[Self.scenarioKey] = scenario
        if let healthRemoval {
            app.launchEnvironment[Self.healthRemovalKey] = healthRemoval
        }
        app.launchArguments += ["-burly-skip-welcome"]
        app.launch()
        return app
    }

    private func openSession(_ id: String, in app: XCUIApplication) {
        let row = anyElement(app, identifier: "historyTab.sessionRow.\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Expected session \(id) in History")
        row.tap()
    }

    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    /// Reveals the row's trailing swipe action and taps Delete.
    private func swipeToDelete(_ row: XCUIElement, sessionID: String, in app: XCUIApplication) {
        let delete = app.buttons["historyTab.deleteSession.\(sessionID)"]
        // A second swipe covers one that landed while a dismissal was still
        // animating.
        for _ in 0..<2 where !delete.exists {
            row.swipeLeft()
            _ = delete.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(delete.exists, "Expected the row's Delete swipe action")
        delete.tap()
    }

    /// Cancels a confirmation dialog. iOS 26 on iPhone draws it as a
    /// popover with no Cancel row, over a full-screen "PopoverDismissRegion";
    /// a tap on that region outside the popover's own frame closes it. An
    /// older action sheet's Cancel button is used when there is one.
    private func dismissDialog(in app: XCUIApplication) {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.waitForExistence(timeout: 2) {
            let popover = app.popovers.firstMatch.frame
            let screen = app.frame
            // Whichever side of the popover has more room.
            let y = popover.minY - screen.minY > screen.maxY - popover.maxY
                ? (popover.minY + screen.minY) / 2
                : (popover.maxY + screen.maxY) / 2
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: screen.midX, dy: y))
                .tap()
        } else {
            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Expected a way to cancel the dialog")
            cancel.tap()
        }
    }

    /// Ends an active search via its own control ("close" in the iOS 26
    /// accessibility tree, as BurlyPhoneUITests notes; "Cancel" before).
    private func closeSearch(in app: XCUIApplication) {
        let close = app.buttons["close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
        } else if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        }
    }

    private func staticText(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func anyElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func firstElement(_ app: XCUIApplication, identifierPrefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
            .firstMatch
    }

    private func identifierSuffix(of element: XCUIElement, prefix: String) -> String? {
        guard element.identifier.hasPrefix(prefix) else { return nil }
        return String(element.identifier.dropFirst(prefix.count))
    }

    /// Swipes up through a lazy list until `identifier` materializes.
    private func scrollToElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = anyElement(app, identifier: identifier)
        for swipeCount in 0...20 {
            if element.waitForExistence(timeout: 1), element.isHittable { return element }
            guard swipeCount < 20 else { break }
            app.swipeUp()
        }
        XCTFail("Expected element \(identifier) after at most 20 upward swipes")
        return element
    }

    /// The DEBUG revision row is the first row of the detail list; scroll
    /// back up until it materializes (see BurlyPhoneUITests.assertRevision).
    private func assertRevision(_ revision: Int, in app: XCUIApplication) {
        let element = anyElement(app, identifier: "historyDetail.revision.\(revision)")
        var found = element.waitForExistence(timeout: 5)
        var swipes = 0
        while !found, swipes < 20 {
            app.swipeDown()
            found = element.waitForExistence(timeout: 1)
            swipes += 1
        }
        XCTAssertTrue(found, "Expected the session at exactly revision \(revision)")
    }

    /// Copied from BurlyPhoneUITests.replaceText: tap the trailing interior
    /// and type through the app, so decimal/number Form fields and plain
    /// fields both take the replacement; the result is asserted.
    private func replaceText(in field: XCUIElement, with value: String, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Expected editable text field")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let existing = editableContents(of: field)
        if !existing.isEmpty {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        app.typeText(value)
        XCTAssertEqual(editableContents(of: field), value, "Expected field \(field.identifier) to hold \(value)")
    }

    private func editableContents(of field: XCUIElement) -> String {
        let raw = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if raw.isEmpty || raw == placeholder { return "" }
        return raw
    }

    private func attachScreenshot(from app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
