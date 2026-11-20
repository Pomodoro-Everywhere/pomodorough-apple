import XCTest

// IOS27-14 and IOS18-05: the completed-focus breakdown control was a second
// primary toolbar item on Arrivals. At the largest text sizes and on a 375 pt
// bar the system folded it, or Account, into "More" and pushed the title off
// centre. It now sits with the arrivals count above the list.
//
// IOS27-17 and IOS27-20: the chart's sectors were separate VoiceOver
// elements with frames wider than the screen, and a landscape phone's chart
// was taller than the visible area.
@MainActor
final class PomodoroughArrivalsBreakdownUITests: XCTestCase {
    private static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let defaultText = "UICTContentSizeCategoryL"

    func testBreakdownAndAccountStayOutOfMoreAtAccessibilityXXXL() {
        assertArrivalsToolbarKeepsAccount(contentSize: Self.largestText)
    }

    func testBreakdownAndAccountStayOutOfMoreAtDefaultSize() {
        assertArrivalsToolbarKeepsAccount(contentSize: Self.defaultText)
    }

    /// At the largest text sizes the count and the control do not fit one
    /// row, so the control stacks below the count. Kept on one row, its
    /// label broke inside a word ("Complet- / ed focus").
    func testBreakdownControlStacksBelowTheCountAtAccessibilityXXXL() {
        continueAfterFailure = false
        let app = arrivalsWithOneCompletedFocus(contentSize: Self.largestText)
        defer { app.terminate() }
        let count = app.staticTexts["1 arrival"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let breakdown = app.buttons["View focus breakdown"]
        XCTAssertTrue(breakdown.waitForExistence(timeout: 5))
        attachScreenshot("ios27-14-arrivals-header-stacked")
        XCTAssertGreaterThanOrEqual(
            breakdown.frame.minY, count.frame.maxY - 1,
            "the control \(breakdown.frame) sits below the count \(count.frame)"
        )
    }

    func testBreakdownChartIsOneElementInsideTheScreen() {
        continueAfterFailure = false
        let app = arrivalsWithOneCompletedFocus(contentSize: Self.defaultText)
        defer { app.terminate() }
        let chart = openBreakdownChart(app)
        attachScreenshot("ios27-17-breakdown-portrait")
        assertChartIsOneElementInsideTheScreen(chart, app: app)
    }

    func testBreakdownChartFitsTheVisibleHeightInLandscape() {
        continueAfterFailure = false
        let app = arrivalsWithOneCompletedFocus(contentSize: Self.defaultText)
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        _ = openBreakdownChart(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [rotated], timeout: 10), .completed)
        let chart = chartElement(in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        attachScreenshot("ios27-20-breakdown-landscape")
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let visibleHeight = app.frame.height - barBottom
        XCTAssertLessThanOrEqual(
            chart.frame.height, visibleHeight,
            "the chart \(chart.frame) fits the \(visibleHeight) pt below the bar"
        )
        assertChartIsOneElementInsideTheScreen(chart, app: app)
    }

    private func assertArrivalsToolbarKeepsAccount(contentSize: String) {
        continueAfterFailure = false
        let app = arrivalsWithOneCompletedFocus(contentSize: contentSize)
        defer { app.terminate() }
        attachScreenshot("ios27-14-arrivals-\(contentSize)")
        let bar = app.navigationBars.firstMatch
        XCTAssertFalse(bar.buttons["More"].exists, "nothing on Arrivals overflows into More")
        let account = bar.buttons["Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        XCTAssertGreaterThan(account.frame.midX, app.frame.midX, "Account stays at the trailing edge")
        let breakdown = app.buttons["View focus breakdown"]
        XCTAssertTrue(breakdown.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(breakdown), "the breakdown control is reachable without More")
        // A 3x screen reports the 44 pt minimum as 43.999999999999986.
        let height = breakdown.frame.height.rounded()
        XCTAssertGreaterThanOrEqual(height, 44, "the breakdown control is a usable touch target")
    }

    private func assertChartIsOneElementInsideTheScreen(_ chart: XCUIElement, app: XCUIApplication) {
        XCTAssertEqual(chart.descendants(matching: .any).count, 0, "the chart element has no sectors inside")
        XCTAssertGreaterThanOrEqual(chart.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(chart.frame.maxX, app.frame.maxX + 1, "the chart \(chart.frame) fits the screen")
        // A sector element is wider than the screen and sits beside the
        // chart element, not inside it, so look at the whole scroll view.
        let screen = app.frame.insetBy(dx: -1, dy: 0)
        let elements = app.scrollViews.firstMatch.descendants(matching: .any).allElementsBoundByIndex
        let offscreen = elements.map(\.frame).filter { $0.minX < screen.minX || $0.maxX > screen.maxX }
        XCTAssertEqual(offscreen, [], "no element is wider than the screen: \(app.debugDescription)")
    }

    private func arrivalsWithOneCompletedFocus(contentSize: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: contentSize)
        tapWhenReachable(app.buttons["Start focus"], in: app)
        tapWhenReachable(app.buttons["Finish timer"], in: app)
        XCTAssertTrue(app.buttons["Start short break"].waitForExistence(timeout: 10))
        app.buttons["Arrivals"].tap()
        XCTAssertTrue(app.buttons["View focus breakdown"].waitForExistence(timeout: 10))
        return app
    }

    private func openBreakdownChart(_ app: XCUIApplication) -> XCUIElement {
        tapWhenReachable(app.buttons["View focus breakdown"], in: app)
        let chart = chartElement(in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        return chart
    }

    private func chartElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Completed focus time by task")).firstMatch
    }

    private func tapWhenReachable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        if !element.isHittable { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(element))
        element.tap()
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
