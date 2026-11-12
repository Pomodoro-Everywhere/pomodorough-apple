import XCTest

/// A silent app on a reset profile in US English, optionally at a forced
/// text size, launched and waiting on the Timer screen.
@MainActor
func launchResetTestApplication(
    contentSize: String? = nil,
    environment: [String: String] = [:]
) -> XCUIApplication {
    let app = silentTestApplication()
    app.launchArguments = [
        "-permission-introduction-completed-v1", "YES",
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
    ]
    if let contentSize {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
    }
    app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
    app.launchEnvironment.merge(environment) { _, new in new }
    app.launch()
    if app.buttons["Start focus"].waitForExistence(timeout: 30) { return app }
    // A fresh runtime can refuse the first launch after install.
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    return app
}

@MainActor
func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
    return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
}
