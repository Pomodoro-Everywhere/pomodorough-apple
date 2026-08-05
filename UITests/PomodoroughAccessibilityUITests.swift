import XCTest

@MainActor
final class PomodoroughAccessibilityUITests: XCTestCase {
    func testVoiceOverUsesOneElementPerTimerTaskAndPhaseControl() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        XCTAssertEqual(elements(labelled: "Focus timer", in: app).count, 1)
        XCTAssertTrue(app.buttons["Start Focus"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).count, 1)
        assertOneElementPerTab(in: app)

        app.buttons["Tasks"].tap()
        XCTAssertEqual(elements(labelled: "Today's routes", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "New task", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "No routes posted", in: app).count, 1)

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
        XCTAssertTrue(app.buttons["Start Focus"].isHittable)

        app.buttons["Tasks"].tap()
        XCTAssertTrue(elements(labelled: "Today's routes", in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(labelled: "New task", in: app).firstMatch.exists)

        app.buttons["Pattern"].tap()
        let focusPhase = elements(labelled: "Focus", in: app).firstMatch
        XCTAssertTrue(focusPhase.waitForExistence(timeout: 5))
        XCTAssertEqual(focusPhase.value as? String, "25 minutes")
    }

    private func makeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-permission-introduction-completed-v1", "YES"]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        return app
    }

    private func launchAndWaitForTimer(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["Start Focus"].waitForExistence(timeout: 10))
    }

    private func elements(labelled label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
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
