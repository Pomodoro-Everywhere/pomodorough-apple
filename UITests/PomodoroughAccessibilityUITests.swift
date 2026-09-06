import XCTest

@MainActor
final class PomodoroughAccessibilityUITests: XCTestCase {
    func testVoiceOverUsesOneElementPerTimerTaskAndPhaseControl() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        XCTAssertEqual(elements(labelled: "Focus timer", in: app).count, 1)
        XCTAssertTrue(app.buttons["Start focus"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).count, 1)
        assertOneElementPerTab(in: app)

        app.buttons["Tasks"].tap()
        XCTAssertEqual(elements(labelled: "Task board", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "New task", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "No tasks yet", in: app).count, 1)

        app.buttons["Pattern"].tap()
        assertPhase(label: "Focus", value: "25 minutes", in: app)
        assertPhase(label: "Short break", value: "5 minutes", in: app)
        assertPhase(label: "Long break", value: "15 minutes", in: app)
        XCTAssertEqual(elements(labelled: "Reduce Focus duration", in: app).count, 0)
        XCTAssertEqual(elements(labelled: "Increase Focus duration", in: app).count, 0)
    }

    func testAccessibilityExtraExtraExtraLargeKeepsCoreTasksReachable() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndWaitForTimer(app)

        XCTAssertTrue(app.navigationBars["Timer"].exists)
        XCTAssertTrue(app.buttons["Start focus"].isHittable)

        app.buttons["Tasks"].tap()
        XCTAssertTrue(elements(labelled: "Task board", in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(labelled: "New task", in: app).firstMatch.exists)

        app.buttons["Pattern"].tap()
        let focusPhase = elements(labelled: "Focus", in: app).firstMatch
        XCTAssertTrue(focusPhase.waitForExistence(timeout: 5))
        XCTAssertEqual(focusPhase.value as? String, "25 minutes")
    }

    func testNetworkSectionExposesModesRoomActionsAndPrivacyCopy() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 5))
        app.buttons["Network"].tap()

        XCTAssertTrue(elements(labelled: "Network replication", in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["On device"].exists)
        XCTAssertTrue(app.buttons["Iroh room"].exists)
        XCTAssertTrue(app.buttons["Pomodorough Cloud"].exists)
        XCTAssertTrue(app.buttons["Create Iroh room"].exists)
        XCTAssertTrue(app.buttons["Join with invite"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@",
            "Peers may see each other's IP addresses"
        )).firstMatch.exists)
    }

    func testEveryPrimaryRouteExposesAccountAndNetworkHierarchy() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        for route in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            app.buttons[route].tap()
            XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 5), "Missing Account on \(route)")
            app.buttons["Account"].tap()
            XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Network"].exists)
            let timerAlertLimits = app.descendants(matching: .any)["account.timer-alert-limits"]
            scrollIntoHierarchy(timerAlertLimits, in: app)
            XCTAssertTrue(timerAlertLimits.exists, "Missing timer alert limits on \(route)")
            app.buttons["Done"].tap()
            XCTAssertFalse(app.navigationBars["Account"].waitForExistence(timeout: 1))
        }
    }

    func testForcedRTLTestConfigurationMirrorsAndKeepsEnglishRoutesReachable() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-NSForceRightToLeftWritingDirection", "YES",
            "-AppleTextDirection", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 10))
        for route in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            XCTAssertTrue(app.buttons[route].exists, "Missing RTL route \(route)")
        }
        XCTAssertGreaterThan(app.buttons["Timer"].frame.midX, app.buttons["Arrivals"].frame.midX)
    }

    func testDialFaceCountdownGrowsWithDynamicType() {
        continueAfterFailure = false
        let app = makeApplication()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXL",
        ]
        launchAndWaitForTimer(app)
        let face = elements(labelled: "Focus timer", in: app).firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 5))
        let defaultHeight = face.frame.height
        XCTAssertGreaterThan(defaultHeight, 0)
        app.terminate()

        app.launchArguments = makeApplication().launchArguments + [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndWaitForTimer(app)
        defer { app.terminate() }
        let largeFace = elements(labelled: "Focus timer", in: app).firstMatch
        XCTAssertTrue(largeFace.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(largeFace.frame.height, defaultHeight)
        XCTAssertTrue(app.buttons["Start focus"].exists)
    }

    func testTaskDeletionCancelKeepsTask() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        createTaskForDeletionTest(named: "UI keep me", in: app)
        let row = elements(labelled: "UI keep me", in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitForHittable(row, timeout: 5)

        tapRowTrashButton(for: row)
        summonDeleteDialog(in: app)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        waitForDisappearance(of: app.buttons["Delete task"], timeout: 5)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testTaskDeletionConfirmRemovesTask() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        createTaskForDeletionTest(named: "UI delete me", in: app)
        let row = elements(labelled: "UI delete me", in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitForHittable(row, timeout: 5)

        tapRowTrashButton(for: row)
        summonDeleteDialog(in: app)
        app.buttons["Delete task"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5))
    }

    private func createTaskForDeletionTest(named title: String, in app: XCUIApplication) {
        app.buttons["Tasks"].tap()
        let field = elements(labelled: "New task", in: app).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons["Add task"].tap()
    }

    private func tapRowTrashButton(for row: XCUIElement) {
        // The row's visible trash button is folded into its accessibility
        // representation, so it cannot be queried as a button. Tap it by
        // coordinate at the row's trailing edge, where the trash icon sits.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func summonDeleteDialog(in app: XCUIApplication) {
        // The trash tap presents the delete confirmation alert directly.
        let delete = app.buttons["Delete task"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed)
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: timeout), .completed)
    }

    private func makeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        return app
    }

    private func launchAndWaitForTimer(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
    }

    private func elements(labelled label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
    }

    private func scrollIntoHierarchy(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.exists {
            app.swipeUp()
        }
    }

    private func assertOneElementPerTab(in app: XCUIApplication) {
        for label in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "Expected one accessibility action for \(label)")
        }
    }

    private func assertPhase(label: String, value: String, in app: XCUIApplication) {
        let matches = elements(labelled: label, in: app)
        XCTAssertEqual(matches.count, 1, "Expected one accessibility element for \(label)")
        XCTAssertEqual(matches.firstMatch.value as? String, value)
    }
}
