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

        // Regression guard: the empty state must live inside the tagged scroll
        // container, which is the refresh gesture's host. Before the fix this
        // branch rendered a bare ContentUnavailableView with no container.
        // (Queried by identifier across all types: the custom accessibility
        // representation changes the exposed element type.)
        let emptyScroll = app.descendants(matching: .any)["history.empty-scroll"].firstMatch
        XCTAssertTrue(emptyScroll.waitForExistence(timeout: 5))

        // Real pull-to-refresh gesture through the UI: must not crash and
        // must leave the empty state (on-device sync finds nothing new).
        emptyScroll.swipeDown()

        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Timer"].exists)
    }
}
