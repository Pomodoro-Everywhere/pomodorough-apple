import XCTest

// IOS27-18 polish: the focus-task menu marks its selection, Tasks shows
// how to rename, Account keeps its trailing slot on Arrivals, and the
// Pattern steppers make room for their symbols at accessibility sizes.
@MainActor
final class PomodoroughPolishUITests: XCTestCase {
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testTaskMenuMarksTheSelectedTask() {
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(waitUntilHittable(picker))
        picker.tap()
        let noTask = app.buttons["No task"]
        XCTAssertTrue(noTask.waitForExistence(timeout: 5))
        attach(named: "IOS27-18-task-menu-selection")
        XCTAssertTrue(noTask.isSelected, "the current choice carries the selected trait and checkmark")
        noTask.tap()
    }

    func testTasksShowTheRenameHint() {
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertFalse(app.staticTexts["tasks.rename-hint"].exists, "no hint on an empty board")
        let composer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "New task")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Draft outline")
        app.buttons["Add task"].tap()
        let hint = app.staticTexts["tasks.rename-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "a board with tasks says how to rename")
        XCTAssertEqual(hint.label, "Touch and hold a task to rename it.")
        attach(named: "IOS27-18-rename-hint")
    }

    func testAccountKeepsTrailingSlotOnArrivals() {
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let account = app.buttons["Account"]
        XCTAssertTrue(waitUntilHittable(account))
        let timerMaxX = account.frame.maxX
        app.buttons["Start focus"].tap()
        let cancel = app.buttons["Cancel timer"]
        XCTAssertTrue(waitUntilHittable(cancel))
        cancel.tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Arrivals"].tap()
        let breakdown = app.buttons["View focus breakdown"]
        XCTAssertTrue(breakdown.waitForExistence(timeout: 10), "history shows the breakdown control")
        attach(named: "IOS27-18-arrivals-toolbar")
        XCTAssertEqual(account.frame.maxX, timerMaxX, accuracy: 2, "Account stays trailing: \(account.frame)")
    }

    func testPatternStepperGrowsAroundItsSymbolAtAccessibilitySizes() {
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        app.tabBars.buttons["Pattern"].tap()
        let reduce = app.buttons["Reduce Short break duration"]
        XCTAssertTrue(reduce.waitForExistence(timeout: 10))
        for _ in 0..<6 where !reduce.isHittable { app.swipeUp() }
        attach(named: "IOS27-18-stepper-ax-xxxl")
        XCTAssertGreaterThan(reduce.frame.width, Self.minimumTouchTarget, "symbol clearance widens \(reduce.frame)")
        // The minus glyph is flat, so only the plus button outgrows the minimum height.
        let increase = app.buttons["Increase Short break duration"]
        XCTAssertTrue(increase.exists)
        XCTAssertGreaterThan(increase.frame.height, Self.minimumTouchTarget, "symbol clearance heightens \(increase.frame)")
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
