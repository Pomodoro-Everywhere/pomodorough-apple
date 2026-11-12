import XCTest

// IOS27-18 and IOS27-03: a failure met inside the Account sheet shows one
// authored sentence, and the sheet with what the person typed stays open.
// The launch environment selects room secret storage that fails like a
// device without the Keychain entitlement, so the failure happens on every
// build, signed or not.
@MainActor
final class PomodoroughAccountFailureUITests: XCTestCase {
    private static let roomName = "R2 release room"
    private static let secureStorageSentence =
        "Pomodorough could not use secure storage on this device. Unlock or restart the device, then try again."

    func testCreateRoomFailureShowsAuthoredSentenceAndKeepsAccountSheet() throws {
        continueAfterFailure = false
        let app = launchNetworkSettings()
        defer { app.terminate() }
        let field = app.textFields["Room name (optional)"]
        let create = app.buttons["Create Iroh room"]
        scroll(to: field, in: app)
        field.tap()
        field.typeText(Self.roomName + "\n")
        scroll(to: create, in: app)
        create.tap()

        let alert = app.alerts["Pomodorough"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "room creation must fail with the failing secret store")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        attachScreenshot(named: "r2-account-failure-sentence")
        XCTAssertFalse(message.contains("OSStatus"), "raw Keychain text reached the person: \(message)")
        XCTAssertFalse(message.contains("34018"), "an error code reached the person: \(message)")
        XCTAssertTrue(message.contains(Self.secureStorageSentence), "unexpected failure text: \(message)")

        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForAbsence(of: alert))
        XCTAssertTrue(create.waitForExistence(timeout: 5), "the Account sheet must stay open after the alert")
        XCTAssertEqual(field.value as? String, Self.roomName, "the typed room name must survive the alert")
        XCTAssertFalse(app.buttons["Start focus"].isHittable, "the Timer must still be covered by the sheet")
        attachScreenshot(named: "r2-account-sheet-after-failure")
    }

    // MARK: - Steps

    private func launchNetworkSettings() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = silentTestApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        app.launchEnvironment["POMODOROUGH_UI_TEST_ROOM_SECRETS"] = "unavailable"
        app.launch()
        if !app.buttons["Start focus"].waitForExistence(timeout: 30) {
            // A fresh runtime can refuse the first install and launch.
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
        }
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 5))
        app.buttons["Network"].tap()
        XCTAssertTrue(app.buttons["Create Iroh room"].waitForExistence(timeout: 5))
        return app
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "\(element) must be reachable")
    }

    private func waitForAbsence(of element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
