import XCTest

@MainActor
final class PomodoroughTimerAlertsRecoveryUITests: XCTestCase {
    func testSkippingOnboardingStillExposesTimerAlertsRecoveryInAccount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // No permission-introduction-completed flag: the intro must appear.
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        defer { app.terminate() }
        app.launch()

        // Regression scenario: user chose "Not now" on first launch. Before
        // the fix there was no in-app route back to the authorization prompt.
        XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: 10))
        app.buttons["Not now"].tap()

        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))

        // Fresh sim install: notification authorization is undetermined, so
        // the status row and the Enable action must be present.
        let status = app.descendants(matching: .any)["account.timer-alerts-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let enable = app.descendants(matching: .any)["account.timer-alerts-enable"].firstMatch
        XCTAssertTrue(enable.waitForExistence(timeout: 5))

        // Do not tap Enable: it raises a system permission prompt that
        // XCUITest cannot reliably dismiss. Presence is the regression guard.
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 5))
    }
}
