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
            XCTAssertTrue(app.staticTexts["Timer alert limits"].exists)
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
