import XCTest

// R54-AU05: at the largest text sizes with a long focus-task title, Start sat
// a full scroll below the countdown. The primary control (Start, Pause,
// Resume) must be visible together with the countdown without scrolling.
// Only the dock-clearance test (L17) scrolls the Timer screen.
@MainActor
final class PomodoroughTimerPrimaryControlUITests: XCTestCase {
    private static let longTitle = "R2 long focus task title that wraps over many lines at the largest text size"
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    func testPrimaryControlStaysVisibleWithCountdownAtAccessibilityXXXL() {
        continueAfterFailure = false
        selectLongFocusTask()
        let app = launchTimer(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }

        for control in ["Start focus", "Pause", "Resume"] {
            assertVisibleWithCountdown(control, in: app)
            attachScreenshot(named: "r2-timer-primary-ax-xxxl-\(control.lowercased().replacingOccurrences(of: " ", with: "-"))")
            app.buttons[control].tap()
        }
        assertVisibleWithCountdown("Pause", in: app)
    }

    func testPrimaryControlStaysVisibleWithCountdownAtEveryLargeTextSize() {
        continueAfterFailure = false
        selectLongFocusTask()
        for size in ["XXXL", "AccessibilityM", "AccessibilityXL", "AccessibilityXXL"] {
            let app = launchTimer(contentSize: "UICTContentSizeCategory\(size)")
            assertVisibleWithCountdown("Start focus", in: app)
            attachScreenshot(named: "r2-timer-primary-\(size.lowercased())-start-focus")
            app.terminate()
        }
    }

    func testPrimaryControlStaysVisibleWithCountdownInLandscapeAtAccessibilityXXXL() {
        continueAfterFailure = false
        selectLongFocusTask()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchTimer(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        attachScreenshot(named: "r2-timer-primary-ax-xxxl-landscape-start-focus")
        assertVisibleWithCountdown("Start focus", in: app)
        app.buttons["Start focus"].tap()
        attachScreenshot(named: "r2-timer-primary-ax-xxxl-landscape-pause")
        assertVisibleWithCountdown("Pause", in: app)
    }

    /// L8: VoiceOver reads the docked primary control before the card's
    /// secondary controls. XCUITest lists elements in accessibility order.
    func testDockedPrimaryControlComesFirstInAccessibilityOrder() {
        continueAfterFailure = false
        selectLongFocusTask()
        let app = launchTimer(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["timer-primary-control-dock"].waitForExistence(timeout: 10))

        let labels = app.buttons.allElementsBoundByIndex.map(\.label)
        let start = labels.firstIndex(of: "Start focus")
        let skip = labels.firstIndex { $0.hasPrefix("Skip to") }
        XCTAssertNotNil(start, "\(labels)")
        XCTAssertNotNil(skip, "\(labels)")
        XCTAssertLessThan(start ?? .max, skip ?? .min, "Start must be read before Skip: \(labels)")
    }

    /// L17: the card scrolls clear of the bottom dock, so its progress bar
    /// can be brought fully above the dock.
    func testCardScrollsClearOfTheBottomDock() {
        continueAfterFailure = false
        selectLongFocusTask()
        let app = launchTimer(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        let dock = app.otherElements["timer-primary-control-dock"]
        let progress = app.progressIndicators["timer-dial-progress"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))

        for _ in 0..<6 where progress.frame.maxY > dock.frame.minY {
            dragCardUp(in: app, above: dock, velocity: .slow)
        }
        attachScreenshot(named: "r2-timer-primary-ax-xxxl-progress-above-dock")
        XCTAssertLessThanOrEqual(progress.frame.maxY, dock.frame.minY, "\(progress.frame) under dock \(dock.frame)")
        XCTAssertTrue(progress.isHittable, "the dock must not cover the progress bar")

        // The card's last control must also clear the dock at the end of the scroll.
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip to")).firstMatch
        XCTAssertTrue(skip.exists)
        for _ in 0..<6 { dragCardUp(in: app, above: dock, velocity: .fast) }
        attachScreenshot(named: "r2-timer-primary-ax-xxxl-scrolled-to-end")
        XCTAssertLessThanOrEqual(skip.frame.maxY, dock.frame.minY, "\(skip.frame) under dock \(dock.frame)")
    }

    // MARK: - Steps

    /// First launch, at the default text size: adds a task with a long title
    /// and makes it the focus task. The workspace keeps it for later launches.
    private func selectLongFocusTask() {
        XCUIDevice.shared.orientation = .portrait
        let app = timerApplication(contentSize: "UICTContentSizeCategoryL")
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        launch(app)
        app.tabBars.buttons["Tasks"].tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(Self.longTitle)
        app.buttons["Add task"].tap()
        let row = app.staticTexts[Self.longTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1)
        let select = app.buttons["Set as focus task"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        app.tabBars.buttons["Timer"].tap()
        XCTAssertTrue(focusTaskPicker(in: app).waitForExistence(timeout: 10), "the long task must be the focus task")
        app.terminate()
    }

    private func launchTimer(contentSize: String) -> XCUIApplication {
        let app = timerApplication(contentSize: contentSize)
        // Shows the real countdown digits instead of the VoiceOver substitute.
        app.launchEnvironment["POMODOROUGH_UI_TEST_DIAL"] = "1"
        launch(app)
        XCTAssertTrue(focusTaskPicker(in: app).waitForExistence(timeout: 10), "the focus task must survive the relaunch")
        return app
    }

    private func timerApplication(contentSize: String) -> XCUIApplication {
        let app = silentTestApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        return app
    }

    private func launch(_ app: XCUIApplication) {
        app.launch()
        if !app.buttons["Start focus"].waitForExistence(timeout: 30) {
            // A fresh runtime can refuse the first install and launch.
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
        }
    }

    private func focusTaskPicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Focus task, \(Self.longTitle)")).firstMatch
    }

    // MARK: - Assertions

    /// The control and the countdown digits both lie between the navigation
    /// bar and the tab bar, and neither covers the other.
    private func assertVisibleWithCountdown(_ label: String, in app: XCUIApplication) {
        let control = app.buttons[label]
        XCTAssertTrue(control.waitForExistence(timeout: 10), "Missing \(label)")
        let digits = app.staticTexts["AP08-countdown-digits"]
        XCTAssertTrue(digits.waitForExistence(timeout: 5), "Missing countdown digits")
        let window = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.frame.maxY
        let visible = CGRect(x: window.minX, y: top, width: window.width, height: app.tabBars.firstMatch.frame.minY - top)
        let frame = control.frame
        XCTAssertTrue(visible.contains(frame), "\(label) must be visible without scrolling: \(frame) in \(visible)")
        XCTAssertTrue(control.isHittable, "\(label) must be hittable without scrolling")
        XCTAssertGreaterThanOrEqual(frame.width, Self.minimumTouchTarget, "\(label) width")
        XCTAssertGreaterThanOrEqual(frame.height, Self.minimumTouchTarget, "\(label) height")
        XCTAssertTrue(
            visible.contains(digits.frame),
            "the countdown must be visible together with \(label): \(digits.frame) in \(visible)"
        )
        XCTAssertTrue(digits.isHittable, "nothing may cover the countdown")
        XCTAssertFalse(frame.intersects(digits.frame), "\(label) must not cover the countdown")
    }

    /// Drags the card, never the dock: a swipe centred on the scroll view
    /// starts on the dock on short phones (iPhone SE), and the dock does not
    /// scroll. The drag runs from just above the dock to near the top.
    private func dragCardUp(in app: XCUIApplication, above dock: XCUIElement, velocity: XCUIGestureVelocity) {
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        let start = origin.withOffset(CGVector(dx: 0, dy: dock.frame.minY * 0.9))
        let end = origin.withOffset(CGVector(dx: 0, dy: dock.frame.minY * 0.2))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
