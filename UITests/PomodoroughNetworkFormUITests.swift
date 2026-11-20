import XCTest

// Network screen room controls and the Join room sheet, light appearance,
// fresh install with no room.
@MainActor
final class PomodoroughNetworkFormUITests: XCTestCase {
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
    }

    // IOS27-18: the room-name field and "Join with invite" meet 44 pt.
    // IOS27-08: the room-name placeholder clears 4.5:1 on its field.
    func testRoomControlsMeetTouchMinimumAndPlaceholderClearsAA() throws {
        let app = launchNetworkScreen()
        defer { app.terminate() }
        let field = app.textFields["Room name (optional)"]
        let join = app.buttons["Join with invite"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<6 where join.frame.maxY > app.frame.height * 0.8 { app.swipeUp() }
        XCTAssertGreaterThanOrEqual(field.frame.height, Self.minimumTouchTarget, "room field \(field.frame)")
        XCTAssertGreaterThanOrEqual(join.frame.height, Self.minimumTouchTarget, "join button \(join.frame)")
        let placeholder = try RenderedContrast.measure(field, in: app, inset: 0.15, minimumPixels: 10)
        XCTAssertGreaterThanOrEqual(placeholder.ratio, 4.5, placeholder.receipt)
        attach(named: "IOS27-18-room-controls")
    }

    // IOS27-02: the sheet title and Cancel are light on the navy backdrop.
    // IOS27-08: the invite placeholder clears 4.5:1 on the porcelain field.
    func testJoinSheetBarAndPlaceholderClearAA() throws {
        let app = launchNetworkScreen()
        defer { app.terminate() }
        openJoinSheet(in: app)
        let bar = app.navigationBars["Join room"]
        let title = bar.staticTexts["Join room"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        attach(named: "IOS27-02-join-sheet-light")
        let titleContrast = try RenderedContrast.measure(title, in: app, inset: 0.1, minimumPixels: 10)
        XCTAssertGreaterThanOrEqual(titleContrast.ratio, 4.5, titleContrast.receipt)
        let cancel = bar.buttons["Cancel"]
        let cancelContrast = try RenderedContrast.measure(cancel, in: app, inset: 0.15, minimumPixels: 10)
        XCTAssertGreaterThanOrEqual(cancelContrast.ratio, 4.5, cancelContrast.receipt)
        let invite = inviteField(in: app)
        let placeholder = try RenderedContrast.measure(invite, in: app, inset: 0.1, minimumPixels: 10)
        XCTAssertGreaterThanOrEqual(placeholder.ratio, 4.5, placeholder.receipt)
    }

    // IOS27-10: typed invite text keeps its exact case and spelling.
    // Synthesized typing bypasses the keyboard's capitals and corrections,
    // so the spelling checker's red underline is the observable symptom.
    func testInviteFieldKeepsTypedTextExact() throws {
        let app = launchNetworkScreen()
        defer { app.terminate() }
        openJoinSheet(in: app)
        let invite = inviteField(in: app)
        invite.tap()
        let typed = "pomodorough1.notarealinvite tset "
        invite.typeText(typed)
        let value = invite.value as? String ?? ""
        XCTAssertEqual(value, typed, "invite field changed the typed text")
        // The checker marks a word a moment after it ends.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach(named: "IOS27-10-invite-typed")
        let marks = try spellingMarkRuns(in: invite, app: app)
        XCTAssertLessThan(marks.map(\.width).reduce(0, +), 10,
            "spelling marks under the invite: \(marks.map { "\($0.width)x\($0.height)" })")
    }

    /// Red column runs in the field that are not the caret. The caret is
    /// one run a line tall and a few pixels wide; on an SE the typed text
    /// wraps, so it can sit anywhere in the field. A spelling mark is a
    /// row of short dots under a word.
    private func spellingMarkRuns(in field: XCUIElement, app: XCUIApplication) throws -> [RenderedPixels.ColumnRun] {
        let runs = try RenderedPixels.columnRuns(in: field.frame, of: XCUIScreen.main.screenshot(), app: app) { red, green, blue in
            red >= 200 && green <= 110 && blue <= 110
        }
        return runs.filter { $0.height < $0.width * 4 }
    }

    private func launchNetworkScreen() -> XCUIApplication {
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        let account = app.buttons["Account"]
        XCTAssertTrue(waitUntilHittable(account))
        account.tap()
        let network = app.buttons["Network"]
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        network.tap()
        XCTAssertTrue(app.buttons["Pomodorough Cloud"].waitForExistence(timeout: 10))
        return app
    }

    private func openJoinSheet(in app: XCUIApplication) {
        let join = app.buttons["Join with invite"]
        XCTAssertTrue(join.waitForExistence(timeout: 10))
        for _ in 0..<6 where !join.isHittable { app.swipeUp() }
        join.tap()
        XCTAssertTrue(app.navigationBars["Join room"].waitForExistence(timeout: 10))
    }

    private func inviteField(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
                "Room invite", XCUIElement.ElementType.textField.rawValue,
                XCUIElement.ElementType.textView.rawValue))
            .firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "invite field exists")
        return field
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
