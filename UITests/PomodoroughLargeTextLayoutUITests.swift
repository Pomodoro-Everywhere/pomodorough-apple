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

    // IOS27-15: at XXXL a phone row split Finish and Cancel into hyphenated
    // "Fin-ish" and "Can-cel" buttons of different heights. They now stack
    // when both labels do not fit on one line, and still share a row at the
    // default size.
    func testFinishAndCancelStackAtAccessibilityXXXL() {
        let (finish, cancel) = runningFinishAndCancelFrames(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertGreaterThanOrEqual(cancel.minY, finish.maxY - 1, "Cancel \(cancel) sits under Finish \(finish)")
        XCTAssertEqual(cancel.width, finish.width, accuracy: 1)
        XCTAssertEqual(cancel.height, finish.height, accuracy: 1)
    }

    func testFinishAndCancelShareARowAtDefaultSize() {
        let (finish, cancel) = runningFinishAndCancelFrames(contentSize: "UICTContentSizeCategoryL")
        XCTAssertEqual(cancel.midY, finish.midY, accuracy: 1, "Cancel \(cancel) sits beside Finish \(finish)")
        XCTAssertGreaterThan(cancel.minX, finish.maxX - 1)
    }

    private func runningFinishAndCancelFrames(contentSize: String) -> (finish: CGRect, cancel: CGRect) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: contentSize)
        defer { app.terminate() }
        let start = app.buttons["Start focus"]
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        let finish = app.buttons["Finish timer"]
        let cancel = app.buttons["Cancel timer"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        for _ in 0..<6 where !(finish.isHittable && cancel.isHittable) { app.swipeUp() }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ios27-15-finish-cancel-\(contentSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return (finish.frame, cancel.frame)
    }
}
