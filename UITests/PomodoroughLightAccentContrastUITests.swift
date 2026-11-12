import XCTest

// IOS27-07: in the light appearance the app tint is the darkened signal, so
// tinted text and glyphs on light surfaces clear 4.5:1. The room-name field
// shows its typed text in the label colour, not the card's porcelain.
// Each test forces the light appearance (CI runs the SE job in dark) and
// restores the previous one; it still checks that the measured surface is
// light before it judges the contrast.
@MainActor
final class PomodoroughLightAccentContrastUITests: XCTestCase {
    private static let minimumContrast = 4.5

    func testSelectedTabLabelClearsContrastOnTheLightTabBar() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = appearance }
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        let tasks = app.tabBars.buttons["Tasks"]
        tasks.tap()
        XCTAssertTrue(tasks.isSelected)
        try assertContrast(of: tasks, named: "IOS27-07-selected-tab", in: app)
    }

    func testTypedRoomNameClearsContrastOnTheWhiteField() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = appearance }
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        app.buttons["Account"].tap()
        let network = app.buttons["Network"]
        XCTAssertTrue(waitUntilHittable(network))
        network.tap()
        let field = app.textFields["Room name (optional)"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText("MMMMMMMMMMMMMMMM")
        try assertContrast(of: field, named: "IOS27-07-room-name", in: app, inset: 0.1)
    }

    private func assertContrast(
        of element: XCUIElement, named name: String, in app: XCUIApplication, inset: CGFloat = 0.2
    ) throws {
        let measured = try RenderedContrast.measure(element, in: app, inset: inset)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        add(XCTAttachment(string: "\(name) \(measured.receipt)"))
        print("B7_PIXELS \(name) \(measured.receipt)")
        XCTAssertGreaterThan(RenderedContrast.luminance(measured.fill), 0.5, "light appearance expected: \(measured.receipt)")
        XCTAssertGreaterThanOrEqual(measured.ratio, Self.minimumContrast, measured.receipt)
    }
}
