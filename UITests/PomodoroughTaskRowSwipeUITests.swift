import XCTest

// R54-AU04: a vertical drag that starts on a task row must scroll the task
// board, and the row's trailing swipe must still open and commit Delete. A
// SwiftUI DragGesture on every row claimed vertical drags on iOS 18 and
// later, so at accessibility sizes, where rows fill most of the screen, the
// board stopped scrolling under the finger.
@MainActor
final class PomodoroughTaskRowSwipeUITests: XCTestCase {
    func testVerticalDragStartingOnTaskRowScrollsBoardAtAccessibilityXXXL() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // Two rows below the target keep the board clear of its scroll limit,
        // where a rubber band would undo the drag after the release.
        let titles = ["AU04 one", "AU04 two", "AU04 three"]
        let app = launchBoard(with: titles, contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        let title = bringUpperRowTitleToMiddle(of: titles, in: app)
        let restingX = title.frame.minX
        let distance = app.scrollViews.firstMatch.frame.height * 0.1
        let start = settledMidY(of: title)
        drag(title.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)), dy: -distance)
        let raised = settledMidY(of: title)
        XCTAssertLessThan(raised, start - distance / 2, "an upward drag that starts on a row must scroll the board")
        drag(title.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)), dy: distance)
        XCTAssertGreaterThan(
            settledMidY(of: title), raised + distance / 2,
            "a downward drag that starts on a row must scroll the board"
        )
        XCTAssertEqual(title.frame.minX, restingX, accuracy: 0.5, "a vertical drag must not move the row sideways")
        XCTAssertFalse(app.buttons["Undo"].exists, "a vertical drag must not delete")
    }

    // The swipe action stays in the XCUI tree while the row is closed, and its
    // reported frame keeps a width after the clip hides it, so open and closed
    // are read from the row offset, which always equals the action's exposure.
    func testPartialSwipeRevealsWorkingDeleteActionAndTapCloses() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchBoard(with: ["AU04 partial"], contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let title = app.staticTexts["AU04 partial"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let restingX = title.frame.minX
        let action = app.buttons["Delete"]
        let isOpen = { title.frame.minX <= restingX - 44 && action.isHittable }
        swipeRow(of: title, fromX: 0.7, toX: 0.4, in: app)
        waitUntil("a partial swipe must reveal the Delete action", isOpen)
        XCTAssertFalse(app.buttons["Undo"].exists, "a partial swipe must not delete")
        title.tap()
        waitUntil("a tap on the open row must close it") { abs(title.frame.minX - restingX) < 0.5 }
        swipeRow(of: title, fromX: 0.7, toX: 0.4, in: app)
        waitUntil("a second partial swipe must reveal the Delete action", isOpen)
        action.tap()
        XCTAssertTrue(
            app.staticTexts["Deleted “AU04 partial”"].waitForExistence(timeout: 5),
            "the revealed Delete action must delete"
        )
    }

    func testFullSwipeDeletesTaskAndUndoRestoresIt() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchBoard(with: ["AU04 full"], contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let title = app.staticTexts["AU04 full"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        swipeRow(of: title, fromX: 0.75, toX: 0.02, in: app)
        XCTAssertTrue(app.staticTexts["Deleted “AU04 full”"].waitForExistence(timeout: 5), "a full swipe must delete")
        waitForSwipeCondition(title, "exists == false", message: "the deleted row must leave the board")
        app.buttons["Undo"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Undo must restore the row")
    }

    // IOS18-03: in a right-to-left layout the row and its Delete action
    // mirror, so a rightward swipe must move the row right, with the finger,
    // and uncover Delete on the left. The gesture read the physical drag
    // with the left-to-right sign, so the row moved against the finger.
    func testRightToLeftSwipeFollowsTheFingerAndRevealsDelete() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let rightToLeft = ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]
        let app = launchBoard(with: ["AU04 mirrored"], contentSize: "UICTContentSizeCategoryL", extraArguments: rightToLeft)
        defer { app.terminate() }
        let title = app.staticTexts["AU04 mirrored"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let restingX = title.frame.minX
        let action = app.buttons["Delete"]
        swipeRow(of: title, fromX: 0.3, toX: 0.6, in: app)
        waitUntil("a rightward swipe must move the row right and reveal Delete") {
            title.frame.minX >= restingX + 44 && action.isHittable
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ios18-03-rtl-swipe-open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThan(action.frame.midX, title.frame.minX, "Delete opens on the left, the trailing edge")
        XCTAssertFalse(app.buttons["Undo"].exists, "a partial swipe must not delete")
    }

    // IOS27-01: in dark mode a closed row must not draw the swipe action's
    // white label under the row's own red trash button. The strip that a
    // full reveal would cover holds only dark fill and the red trash glyph.
    func testClosedRowDrawsNoSwipeLabelInDarkAppearance() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        // A failed assertion aborts the test without running `defer`.
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance }
        let app = launchBoard(with: ["AU04 ghost"], contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let trash = app.buttons["Delete AU04 ghost"]
        XCTAssertTrue(trash.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Delete"].exists, "a closed row must not expose the swipe action")
        // SwipeToDeleteMetrics.revealFraction of the row; the row spans
        // nearly the screen, so the screen width bounds the full reveal.
        let reveal = app.frame.width * 0.3
        let strip = CGRect(x: app.frame.maxX - reveal, y: trash.frame.minY, width: reveal, height: trash.frame.height)
        try waitForDarkRow(in: strip, app: app)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "IOS27-01-closed-row-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
        let white = try RenderedPixels.count(in: strip, of: shot, app: app) { red, green, blue in
            min(red, green, blue) >= 200
        }
        XCTAssertLessThan(white, 20, "white pixels in the closed row's trailing strip: \(white)")
    }

    /// The simulator can apply the appearance change late. Observed once on
    /// iOS 27.2: a full class run kept drawing light for the whole test.
    /// A light row would pass the white-pixel check for the wrong reason
    /// (the card itself is white), so the test skips with that reason.
    private func waitForDarkRow(in strip: CGRect, app: XCUIApplication) throws {
        var dark = 0
        let deadline = Date().addingTimeInterval(20)
        while dark <= 1_000, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            dark = try RenderedPixels.count(in: strip, of: XCUIScreen.main.screenshot(), app: app) { red, green, blue in
                max(red, green, blue) <= 60
            }
        }
        try XCTSkipIf(dark <= 1_000, "the simulator did not draw the dark appearance: \(dark) dark pixels")
    }

    /// Adds the tasks, then relaunches so the composer keyboard is gone and
    /// the board opens scrolled to the top.
    private func launchBoard(
        with titles: [String], contentSize: String, extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = silentTestApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", contentSize,
        ] + extraArguments
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        launchSwipeApp(app)
        app.buttons["Tasks"].tap()
        for title in titles { addSwipeTask(named: title, in: app) }
        app.terminate()
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = nil
        launchSwipeApp(app)
        app.buttons["Tasks"].tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 10))
        return app
    }

    private func launchSwipeApp(_ app: XCUIApplication) {
        app.launch()
        if app.buttons["Start focus"].waitForExistence(timeout: 30) { return }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    }

    private func addSwipeTask(named title: String, in app: XCUIApplication) {
        let field = composerField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        waitForSwipeCondition(field, "value == %@", title, message: "typed text must reach the field before Add")
        app.buttons["Add task"].tap()
        // Add clears the composer only after the task is stored.
        waitForSwipeCondition(app.buttons["Add task"], "isEnabled == false", message: "Add must store \(title)")
    }

    /// Scrolls with drags that start above every row, so they move the board
    /// on the broken baseline too, until the upper row's title sits in the
    /// middle band with board left to scroll below it.
    private func bringUpperRowTitleToMiddle(of titles: [String], in app: XCUIApplication) -> XCUIElement {
        let scroll = app.scrollViews.firstMatch
        let band = (scroll.frame.minY + scroll.frame.height * 0.35)...(scroll.frame.minY + scroll.frame.height * 0.6)
        for _ in 0..<8 {
            let title = upperRowTitle(of: titles, in: app)
            if let title, band.contains(settledMidY(of: title)) { return title }
            if let title, title.frame.midY < band.lowerBound {
                XCTFail("upper row starts above the drag band at \(title.frame.midY)")
                return title
            }
            drag(scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.25)), dy: -scroll.frame.height * 0.2)
        }
        XCTFail("upper task row never reached the middle of the board")
        return app.staticTexts[titles[0]]
    }

    private func upperRowTitle(of titles: [String], in app: XCUIApplication) -> XCUIElement? {
        titles
            .map { app.staticTexts[$0] }
            .filter { $0.exists }
            .min { $0.frame.minY < $1.frame.minY }
    }

    /// Reads the element's midY once the board stops moving, so a bounce or
    /// deceleration after a release never reaches a measurement.
    private func settledMidY(of element: XCUIElement) -> CGFloat {
        var last = element.frame.midY
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let next = element.frame.midY
            if abs(next - last) < 0.5 { return next }
            last = next
        }
        XCTFail("the board never settled")
        return last
    }

    /// The release holds still so the board settles without momentum.
    private func drag(_ start: XCUICoordinate, dy: CGFloat) {
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(.init(dx: 0, dy: dy)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
    }

    private func swipeRow(of title: XCUIElement, fromX: CGFloat, toX: CGFloat, in app: XCUIApplication) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let width = app.frame.width
        let y = title.frame.midY - app.frame.minY
        origin.withOffset(.init(dx: width * fromX, dy: y)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(.init(dx: width * toX, dy: y)),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
    }

    private func composerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
    }

    private func waitForSwipeCondition(_ element: XCUIElement, _ format: String, _ args: Any..., message: String) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let condition = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [condition], timeout: 15), .completed, message)
    }

    /// Polls a condition on element geometry, which settles after the row's
    /// snap animation.
    private func waitUntil(_ message: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(condition(), message)
    }
}
