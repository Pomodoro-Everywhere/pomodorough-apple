import XCTest

// IOS27-05: the focus-task picker opens from anywhere on its row. It used to
// answer only on the title line, a band 15 to 17 points high.
@MainActor
final class PomodoroughTimerTaskPickerUITests: XCTestCase {
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    func testPickerOpensFromTheCaptionCorner() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(waitUntilHittable(picker))
        XCTAssertGreaterThanOrEqual(picker.frame.height, Self.minimumTouchTarget, "picker frame \(picker.frame)")
        // Near the leading top corner: the FOCUS TASK caption, not the title.
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2)).tap()
        let noTask = app.buttons["No task"]
        XCTAssertTrue(noTask.waitForExistence(timeout: 5), "a tap on the caption opens the task menu")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "IOS27-05-menu-from-caption"
        shot.lifetime = .keepAlways
        add(shot)
        noTask.tap()
    }
}
