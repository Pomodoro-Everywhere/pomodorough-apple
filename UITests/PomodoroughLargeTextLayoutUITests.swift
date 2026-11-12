import XCTest

// B5 (IOS27-13): at accessibility text sizes a task row used to keep its
// delete button beside a title that wrapped over many lines, so the row
// grew one to three screens tall with the button halfway down. The row now
// stacks: title first, then the badge, the summary and the delete button.
@MainActor
final class PomodoroughLargeTextLayoutUITests: XCTestCase {
    private static let longTitle = "B5 long task title that wraps over several lines at the largest text size"

    func testTaskRowPutsDeleteUnderTheTitleAtAccessibilityXXXL() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        app.tabBars.buttons["Tasks"].tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(Self.longTitle)
        app.buttons["Add task"].tap()

        let title = app.staticTexts[Self.longTitle]
        let delete = app.buttons["Delete \(Self.longTitle)"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "r2-b5-task-row-ax-xxxl"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertGreaterThanOrEqual(
            delete.frame.minY, title.frame.maxY - 1,
            "the delete button follows the title: title \(title.frame), delete \(delete.frame)"
        )
        XCTAssertLessThanOrEqual(
            delete.frame.minX, title.frame.midX,
            "the delete button starts the next line, not the far edge: title \(title.frame), delete \(delete.frame)"
        )
    }
}
