import XCTest
import UIKit

// IOS27-19: the phone landscape Timer hides the tab bar and the toolbar.
// A labelled control brings them back without rotating the phone.
@MainActor
final class PomodoroughLandscapeChromeUITests: XCTestCase {
    /// System minimum touch target, in points.
    private static let minimumTouchTarget: CGFloat = 44

    func testShowTabsRestoresTabBarAndToolbarInPhoneLandscape() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "regular landscape keeps its chrome")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchResetTestApplication(contentSize: "UICTContentSizeCategoryL")
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let show = app.buttons["timer.show-tabs"]
        XCTAssertTrue(waitUntilHittable(show), "the landscape Timer offers a way back to the tabs")
        XCTAssertFalse(app.tabBars.buttons["Tasks"].isHittable, "the landscape card still hides the tab bar")
        XCTAssertEqual(show.label, "Show tabs")
        XCTAssertGreaterThanOrEqual(show.frame.width, Self.minimumTouchTarget)
        XCTAssertGreaterThanOrEqual(show.frame.height, Self.minimumTouchTarget)

        show.tap()
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Tasks"]), "Show tabs restores the tab bar")
        XCTAssertTrue(waitUntilHittable(app.buttons["Account"]), "Show tabs restores the toolbar")
        XCTAssertFalse(show.exists, "the control goes away once the tabs are shown")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "IOS27-19-landscape-tabs-shown"
        shot.lifetime = .keepAlways
        add(shot)

        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["New task"].waitForExistence(timeout: 10))
    }
}
