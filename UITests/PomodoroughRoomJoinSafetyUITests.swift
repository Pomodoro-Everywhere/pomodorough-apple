import XCTest

@MainActor
final class PomodoroughRoomJoinSafetyUITests: XCTestCase {
    func testFailedJoinKeepsSheetAndLeavesWorkspaceUnchanged() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 5))
        app.buttons["Network"].tap()
        app.buttons["Join with invite"].tap()
        XCTAssertTrue(app.navigationBars["Join room"].waitForExistence(timeout: 5))

        // Empty invite must not start a join.
        XCTAssertFalse(app.buttons["Validate and join"].isEnabled)

        // Malformed invite fails fast in local invite decoding, before any
        // networking: deterministic failed join without a slow peer.
        let inviteField = app.textFields["Room invite"].firstMatch
        XCTAssertTrue(inviteField.waitForExistence(timeout: 5))
        inviteField.tap()
        inviteField.typeText("not-a-valid-invite")
        app.buttons["Validate and join"].tap()

        // Regression guard for the dismissal race: the sheet must still be
        // here after the failure (no silent workspace switch behind it) and
        // Cancel must be usable again.
        sleep(3)
        XCTAssertTrue(app.navigationBars["Join room"].exists)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.isEnabled)
        cancel.tap()

        // Workspace untouched: back on the idle local timer.
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 5))
    }
}
