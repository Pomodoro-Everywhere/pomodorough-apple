import XCTest

// IOS27-06: the undo window for a deleted task has no time limit. It ends
// when the user chooses Undo or Delete now, deletes another task, opens
// Account, or leaves the Tasks screen. The banner used to commit the
// deletion after five seconds. The window is durable: a process killed
// inside it finishes the deletion at the next start.
@MainActor
final class PomodoroughTaskDeletionUndoUITests: XCTestCase {
    /// Longer than the five-second timeout the undo window used to have.
    private static let formerTimeout: TimeInterval = 7
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    func testUndoBannerOutlastsFormerTimeoutAndDeleteNowCommits() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 dismiss me", in: app)

        Thread.sleep(forTimeInterval: Self.formerTimeout)
        let undo = undoButton(in: app)
        let deleteNow = deleteNowButton(in: app)
        XCTAssertTrue(undo.exists, "the undo window must not end on a timer")
        XCTAssertTrue(app.staticTexts["Deleted “R2 dismiss me”"].exists)
        XCTAssertEqual(deleteNow.label, "Delete now", "the second button says what it does")
        assertReachable(undo, in: app)
        assertReachable(deleteNow, in: app)
        assertBannerClearsComposer(undo: undo, dismiss: deleteNow, in: app)
        attachScreenshot(named: "r2-undo-banner-after-former-timeout")

        deleteNow.tap()
        waitForAbsence(of: undo)
        XCTAssertFalse(row.waitForExistence(timeout: 2), "Delete now must finish the deletion")
    }

    func testUndoRestoresTaskAfterFormerTimeout() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 keep me", in: app)

        Thread.sleep(forTimeInterval: Self.formerTimeout)
        let undo = undoButton(in: app)
        XCTAssertTrue(undo.exists, "Undo must still be offered after the former timeout")
        undo.tap()
        waitForAbsence(of: undo)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo must restore the row")
    }

    func testLeavingTasksScreenEndsUndoWindow() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 leave me", in: app)

        app.tabBars.buttons["Timer"].tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 10))

        XCTAssertFalse(undoButton(in: app).exists, "leaving the Tasks screen must end the undo window")
        XCTAssertFalse(row.exists, "leaving the Tasks screen must finish the deletion")
    }

    func testOpeningAccountEndsUndoWindow() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 account fence", in: app)

        app.buttons["Account"].firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Account must open")
        done.tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 10))

        XCTAssertFalse(undoButton(in: app).exists, "opening Account must end the undo window")
        XCTAssertFalse(row.exists, "opening Account must finish the deletion")
    }

    func testKillDuringUndoWindowKeepsTheTaskDeletedAfterRelaunch() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        _ = deleteNewTask(named: "R2 killed window", in: app)

        app.terminate()
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = nil
        launchUntilTimer(app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 10))

        XCTAssertFalse(app.staticTexts["R2 killed window"].exists, "a deleted task must not come back")
        XCTAssertFalse(undoButton(in: app).exists)
    }

    func testUndoThenKillKeepsTheTaskAfterRelaunch() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 undone window", in: app)
        undoButton(in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        app.terminate()
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = nil
        launchUntilTimer(app)
        app.tabBars.buttons["Tasks"].tap()

        XCTAssertTrue(app.staticTexts["R2 undone window"].waitForExistence(timeout: 10), "Undo must survive a restart")
    }

    func testUndoBannerActionsStayReachableAtAccessibilityXXXL() {
        continueAfterFailure = false
        let app = launchTasks(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        let row = deleteNewTask(named: "R2 large text", in: app)

        let undo = undoButton(in: app)
        let deleteNow = deleteNowButton(in: app)
        assertReachable(undo, in: app)
        assertReachable(deleteNow, in: app)
        XCTAssertFalse(undo.frame.intersects(deleteNow.frame), "Undo and Delete now must not overlap")
        attachScreenshot(named: "r2-undo-banner-xxxl")

        undo.tap()
        waitForAbsence(of: undo)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo must restore the row")
    }

    // MARK: - Steps

    private func launchTasks(contentSize: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = silentTestApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        launchUntilTimer(app)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 10))
        return app
    }

    private func launchUntilTimer(_ app: XCUIApplication) {
        app.launch()
        if app.buttons["Start focus"].waitForExistence(timeout: 30) { return }
        // A fresh runtime can refuse the first install and launch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    }

    /// Adds a task, deletes it with the row's trash button, and returns the
    /// row title element, which the open undo window hides.
    private func deleteNewTask(named title: String, in app: XCUIApplication) -> XCUIElement {
        let field = composerField(in: app)
        field.tap()
        field.typeText(title)
        app.buttons["Add task"].tap()
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let trash = app.buttons["Delete \(title)"]
        for _ in 0..<4 where !trash.isHittable { app.swipeUp() }
        XCTAssertTrue(trash.isHittable, "the row's Delete button must be reachable")
        trash.tap()
        XCTAssertTrue(undoButton(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists, "a pending deletion must leave the board immediately")
        return row
    }

    private func undoButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["task-deletion.undo"]
    }

    private func deleteNowButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["task-deletion.delete-now"]
    }

    private func composerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
    }

    // MARK: - Assertions

    private func assertReachable(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.exists, "\(button) must exist")
        XCTAssertTrue(button.isHittable, "\(button) must be hittable")
        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.width, Self.minimumTouchTarget, "\(button) width")
        XCTAssertGreaterThanOrEqual(frame.height, Self.minimumTouchTarget, "\(button) height")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "\(button) must stay inside the window")
    }

    private func assertBannerClearsComposer(undo: XCUIElement, dismiss: XCUIElement, in app: XCUIApplication) {
        let banner = undo.frame.union(dismiss.frame)
        for control in [composerField(in: app), app.buttons["Add task"]] where control.exists {
            XCTAssertFalse(banner.intersects(control.frame), "the undo banner must not cover \(control)")
        }
        let tabBar = app.tabBars.firstMatch
        XCTAssertLessThanOrEqual(banner.maxY, tabBar.frame.minY, "the undo banner must sit above the tab bar")
    }

    private func waitForAbsence(of element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "\(element) must leave")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
