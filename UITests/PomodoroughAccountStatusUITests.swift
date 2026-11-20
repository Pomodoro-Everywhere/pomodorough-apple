import XCTest

// Signed-out Account and toolbar status on a fresh install: Cloud is the
// selected line and no account exists.
@MainActor
final class PomodoroughAccountStatusUITests: XCTestCase {
    // IOS27-11: a blocked "Sync now" says why, under the button.
    func testBlockedSyncNowShowsItsReason() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        openAccount(in: app)
        let syncNow = app.buttons["Sync now"]
        reveal(syncNow, in: app)
        XCTAssertFalse(syncNow.isEnabled, "signed out, Cloud cannot sync")
        let reason = app.staticTexts["Sign in with Google to sync."]
        XCTAssertTrue(reason.exists, "the blocked button shows its reason")
        XCTAssertLessThan(abs(reason.frame.minY - syncNow.frame.maxY), syncNow.frame.height,
            "the reason sits under the button: \(reason.frame) \(syncNow.frame)")
        attachScreenshot(named: "IOS27-11-sync-now-reason")
    }

    // IOS27-12: the toolbar status, Account and Network agree that Cloud
    // is selected and waits for sign-in.
    func testSignedOutCloudWordingAgrees() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let status = signedOutStatus(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "toolbar status names the missing sign-in")
        XCTAssertFalse(app.descendants(matching: .any)["Sync status, On device"].exists)
        openAccount(in: app)
        let network = app.buttons["Network"]
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        let summary = network.value as? String ?? ""
        XCTAssertTrue(summary.hasPrefix("Signed out;"), "Account network summary: \(summary)")
        network.tap()
        let cloud = app.buttons["Pomodorough Cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10))
        XCTAssertEqual(cloud.value as? String, "Selected, signed out")
        XCTAssertEqual(app.buttons["On device"].value as? String, "Not selected")
        attachScreenshot(named: "IOS27-12-network-signed-out")
    }

    // IOS27-08: the toolbar status chip and Account row values clear 4.5:1.
    func testSignedOutStatusAndAccountValuesClearAA() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = appearance }
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let status = signedOutStatus(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let chip = try RenderedContrast.measure(status, in: app, inset: 0.1, minimumPixels: 10)
        XCTAssertGreaterThanOrEqual(chip.ratio, 4.5, chip.receipt)
        openAccount(in: app)
        let alerts = app.descendants(matching: .any)["account.timer-alerts-status"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 10))
        let shot = XCUIScreen.main.screenshot()
        // The value is trailing; the system grey composite is (138, 138, 143)
        // and antialiasing only lightens, so no value pixel was this dark.
        let valueSide = CGRect(x: alerts.frame.midX, y: alerts.frame.minY,
            width: alerts.frame.width / 2, height: alerts.frame.height)
        let dark = try RenderedPixels.count(in: valueSide, of: shot, app: app) { red, green, blue in
            max(red, green, blue) <= 100
        }
        XCTAssertGreaterThan(dark, 20, "value glyph pixels at the pinned grey: \(dark)")
        attachScreenshot(named: "IOS27-08-account-values")
    }

    // IOS27-08 and IOS27-12: the glass bar draws the whole status chip on
    // Timer and beside the wide Arrivals controls.
    func testSignedOutStatusChipDrawsItsWholeLabel() throws {
        continueAfterFailure = false
        let app = launchInLightAppearance(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        try assertStatusChipDrawsItsWholeLabel(in: app, shot: "IOS27-08-status-chip-timer")
        app.buttons["Start focus"].tap()
        let cancel = app.buttons["Cancel timer"]
        XCTAssertTrue(waitUntilHittable(cancel))
        cancel.tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Arrivals"].tap()
        XCTAssertTrue(app.buttons["View focus breakdown"].waitForExistence(timeout: 10))
        try assertStatusChipDrawsItsWholeLabel(in: app, shot: "IOS27-08-status-chip-arrivals")
    }

    func testSignedOutStatusChipDrawsItsWholeLabelAtAccessibilityXXXL() throws {
        continueAfterFailure = false
        let app = launchInLightAppearance(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        try assertStatusChipDrawsItsWholeLabel(in: app, shot: "IOS27-08-status-chip-ax-xxxl")
    }

    private func launchInLightAppearance(contentSize: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        // A failed assertion ends the test without running defer blocks.
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = appearance }
        return launchResetTestApplication(contentSize: contentSize)
    }

    /// The chip label is monospaced, so each letter draws its own run of
    /// pixel columns in the pinned light-appearance grey. A cut label draws
    /// fewer runs; ellipsis dots are too short to count as letters.
    private func assertStatusChipDrawsItsWholeLabel(in app: XCUIApplication, shot: String) throws {
        let status = signedOutStatus(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        attachScreenshot(named: shot)
        let runs = try RenderedPixels.columnRuns(in: status.frame, of: XCUIScreen.main.screenshot(), app: app) { red, green, blue in
            max(red, green, blue) <= 120 && max(red, green, blue) - min(red, green, blue) <= 24
        }
        let tallest = runs.map(\.height).max() ?? 0
        let letters = runs.filter { $0.height * 10 >= tallest * 6 }
        let receipt = "chip \(status.frame) draws \(runs.map { "\($0.width)x\($0.height)" })"
        XCTAssertEqual(letters.count, "SIGNEDOUT".count, receipt)
        let widths = letters.map(\.width)
        XCTAssertGreaterThanOrEqual((widths.min() ?? 0) * 2, widths.max() ?? 1, "a letter is cut: \(receipt)")
    }

    /// The status is one button for VoiceOver. On iOS 18 its bar item host
    /// is a container that repeats the label, so an any-type query matches
    /// both and cannot read a single frame.
    private func signedOutStatus(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Sync status, Signed out"]
    }

    private func openAccount(in app: XCUIApplication) {
        let account = app.buttons["Account"]
        XCTAssertTrue(waitUntilHittable(account))
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
    }

    /// The Account list is lazy: a row below the fold is not in the
    /// hierarchy until the list scrolls to it.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.exists { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) exists")
        for _ in 0..<6 where element.frame.maxY > app.frame.height * 0.8 { app.swipeUp() }
        XCTAssertTrue(app.frame.contains(element.frame), "\(element) is on screen")
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
