import XCTest

// B8: the composer refuses a draft that is empty or only whitespace, the
// duration stepper stops at the bounds Core accepts (1 to 180 minutes), and
// a new cancelled history row shows the minutes Core recorded, not its plan.
// Only rows stored before Core 0.55.0 (no elapsedMs) word their minutes as
// planned; unit tests pin that branch (InputRulesTests, HistoryElapsedTests).
@MainActor
final class PomodoroughInputRulesUITests: XCTestCase {
    func testWhitespaceDraftKeepsAddTaskDisabled() {
        continueAfterFailure = false
        let app = launchResetTestApplication()
        defer { app.terminate() }
        app.tabBars.buttons["Tasks"].tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText("   ")
        let add = app.buttons["Add task"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(add.isEnabled, "a draft of spaces is blank and cannot be added")
        field.typeText(" a ")
        XCTAssertTrue(add.isEnabled, "a draft with one letter can be added; nothing else is trimmed")
    }

    func testReduceStopsAtTheMinimumDuration() {
        continueAfterFailure = false
        let app = launchResetTestApplication()
        defer { app.terminate() }
        app.tabBars.buttons["Pattern"].tap()
        let reduce = app.buttons["Reduce Short break duration"]
        let minutes = app.staticTexts["Short break duration"]
        XCTAssertTrue(reduce.waitForExistence(timeout: 10))
        for _ in 0..<4 where !reduce.isHittable { app.swipeUp() }
        // The reset profile starts at 5 minutes; ten taps reach the floor.
        for _ in 0..<10 where reduce.isEnabled {
            reduce.tap()
        }
        // The catalog plural rule speaks the floor in the singular.
        XCTAssertEqual(minutes.value as? String, "1 minute")
        XCTAssertFalse(reduce.isEnabled, "minus is disabled at the 1 minute minimum")
        XCTAssertTrue(app.buttons["Increase Short break duration"].isEnabled)
    }

    func testCancelledFocusRowSpeaksRecordedMinutes() {
        continueAfterFailure = false
        let app = launchResetTestApplication()
        defer { app.terminate() }
        app.buttons["Start focus"].tap()
        let cancel = app.buttons["Cancel timer"]
        XCTAssertTrue(waitUntilHittable(cancel))
        cancel.tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Arrivals"].tap()
        // Core fills elapsedMs on every projected row, so the row speaks the
        // recorded time ("0 minutes" or "1 minute"), never the 25 minute plan.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Focus, ", ", Cancelled, "))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the cancelled focus run is listed")
        XCTAssertTrue(row.label.contains(" minute"), "a cancelled row speaks its duration, got \(row.label)")
        XCTAssertFalse(row.label.contains("planned"), "a recorded cancelled row is not worded as planned, got \(row.label)")
        XCTAssertFalse(row.label.contains("25 minutes"), "a cancelled row does not speak its plan, got \(row.label)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "B8-cancelled-row-recorded"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
