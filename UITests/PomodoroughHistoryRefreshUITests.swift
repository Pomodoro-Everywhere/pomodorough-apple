import XCTest

@MainActor
final class PomodoroughHistoryRefreshUITests: XCTestCase {
    func testEmptyHistoryExposesRefreshableScrollAndSurvivesPull() {
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
        app.buttons["Arrivals"].tap()

        let emptyLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "No arrivals yet")).firstMatch
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5))

        // Keep the refresh host accessible, not replaced by static text.
        let emptyScroll = app.scrollViews["history.empty-scroll"].firstMatch
        XCTAssertTrue(emptyScroll.waitForExistence(timeout: 5))

        // Real pull-to-refresh gesture through the UI: must not crash and
        // must leave the empty state (on-device sync finds nothing new).
        emptyScroll.swipeDown()

        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Timer"].exists)
    }
}
