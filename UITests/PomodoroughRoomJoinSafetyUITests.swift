import XCTest

@MainActor
final class PomodoroughRoomJoinSafetyUITests: XCTestCase {
    func testFailedJoinKeepsSheetAndLeavesWorkspaceUnchanged() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        openJoinSheet(app)

        // Empty invite must not start a join.
        XCTAssertFalse(app.buttons["Validate and join"].isEnabled)
        app.terminate()

        // Malformed invite fails fast in local invite decoding, before any
        // networking: deterministic failed join without a slow peer. The
        // invite arrives via launch-environment prefill, not the keyboard:
        // unresolved hypothesis is that focusing a field may hang
        // narrow-simulator main threads (requires physical-SE verification
        // and an Apple Feedback filing), while the regression under test
        // (failed join keeps the sheet) needs no keys.
        app.launchEnvironment["POMODOROUGH_UI_TEST_INVITE"] = "not-a-valid-invite"
        app.launch()

        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        openJoinSheet(app)

        XCTAssertTrue(app.buttons["Validate and join"].isEnabled)
        app.buttons["Validate and join"].tap()

        // Regression guard for the dismissal race: the sheet must still be
        // here after the failure (no silent workspace switch behind it) and
        // Cancel must be usable again.
        assertFailedJoinKeepsSheet(app)

        // Workspace untouched: back on the idle local timer.
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 5))
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

    private func openJoinSheet(_ app: XCUIApplication) {
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 5))
        app.buttons["Network"].tap()
        app.buttons["Join with invite"].tap()
        XCTAssertTrue(app.navigationBars["Join room"].waitForExistence(timeout: 5))
    }

    private func assertFailedJoinKeepsSheet(_ app: XCUIApplication) {
        sleep(3)
        dumpRoomJoinDiagnostics(app, "post-failure")
        XCTAssertTrue(app.staticTexts["Join room error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Join room"].exists)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.isEnabled)
        cancel.tap()
    }

    private func dumpRoomJoinDiagnostics(_ app: XCUIApplication, _ context: String) {
        let sheet = app.navigationBars["Join room"]
        let cancel = app.buttons["Cancel"]
        print("ROOM-JOIN-DIAG \(context): navBar=\(sheet.exists) alerts=\(app.alerts.count) cancel=\(cancel.exists)")
        if !sheet.exists {
            print("ROOM-JOIN-DIAG hierarchy:\n" + app.debugDescription)
        }
    }
}
