import XCTest

// R53-AU01: Tasks composer focus legs in a host with a working focus store
// (real app UI). The unit-test host FocusState never delivers (a detached
// FocusState's wrappedValue setter is a no-op: reads back false), so T4/T5
// observable outcomes pin here: T5 tap focuses and the full string
// persists; T4 submit commits the full title, clears the composer, and
// disables Add; T4b navigating away commits ahead-of-binding text so Add
// still creates the full title without refocusing.
@MainActor
final class PomodoroughAU01ComposerFocusUITests: XCTestCase {
    func testAU01TapFocusesAndFullStringPersists() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeAU01App()
        defer { app.terminate() }
        launchAU01(app)
        let field = au01Field(in: app)
        field.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 10)
        field.typeText("AU01 focus T5")
        XCTAssertTrue(app.buttons["Add task"].isEnabled)
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.contains("AU01 focus T5"), "value=\(value)")
    }

    func testAU01SubmitCommitsFullTitleAndClears() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeAU01App()
        defer { app.terminate() }
        launchAU01(app)
        let field = au01Field(in: app)
        field.tap()
        field.typeText("AU01 resign T4")
        app.buttons["Add task"].tap()
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", "AU01 resign T4"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(matches.count, 1, "Add creates exactly one task")
        // addTask clears asynchronously (await model.addTask, then title=""),
        // so poll for the push into the field instead of a single-shot read.
        var cleared = ""
        let deadline = Date(timeIntervalSinceNow: 10)
        repeat {
            cleared = (au01FieldValue(in: app).value as? String) ?? ""
            if cleared == "" || cleared == "Write release notes" { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        XCTAssertTrue(cleared == "" || cleared == "Write release notes", "value=\(cleared)")
        XCTAssertFalse(app.buttons["Add task"].isEnabled)
    }

    func testAU01UnfocusCommitsFullTitleForAdd() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeAU01App()
        defer { app.terminate() }
        launchAU01(app)
        let field = au01Field(in: app)
        field.tap()
        field.typeText("AU01 unfocus T4b")
        // Resign by navigating away: the true->false pass must commit the
        // ahead-of-binding text instead of dropping it.
        app.buttons["Timer"].tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.buttons["Tasks"].tap()
        let returned = au01FieldValue(in: app)
        let kept = returned.value as? String ?? ""
        XCTAssertTrue(kept.contains("AU01 unfocus T4b"), "resign dropped text, value=\(kept)")
        app.buttons["Add task"].tap()
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", "AU01 unfocus T4b"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(matches.count, 1, "Add creates exactly one task")
    }

    private func makeAU01App() -> XCUIApplication {
        let app = silentTestApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        return app
    }

    private func launchAU01(_ app: XCUIApplication) {
        app.launch()
        if app.buttons["Start focus"].waitForExistence(timeout: 30) { return }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    }

    private func au01Field(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Tasks"].tap()
        return au01FieldValue(in: app)
    }

    private func au01FieldValue(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New task")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }
}
