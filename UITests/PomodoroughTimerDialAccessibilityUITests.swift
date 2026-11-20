import XCTest

// IOS27-09: the dial's VoiceOver elements were a substitute representation
// that took its intrinsic text size, so "Focus timer" was a 90x20 pt frame
// in the dial's top-left corner and touch exploration on the countdown read
// nothing. The timer element must now cover the visible countdown, and the
// progress element must sit on the visible progress dots.
//
// The probe launch (POMODOROUGH_UI_TEST_DIAL) exposes the rendered digits
// and dots; the production launch exposes only the VoiceOver elements. The
// layout is the same in both, so the frames can be compared.
@MainActor
final class PomodoroughTimerDialAccessibilityUITests: XCTestCase {
    private struct DialFrames {
        let readout: CGRect
        let progress: CGRect
    }

    func testTimerElementCoversTheCountdownInPortrait() {
        assertDialElementsMatchRenderedReadout(contentSize: "UICTContentSizeCategoryL", orientation: .portrait)
    }

    func testTimerElementCoversTheCountdownAtAccessibilityXXXL() {
        assertDialElementsMatchRenderedReadout(
            contentSize: "UICTContentSizeCategoryAccessibilityXXXL", orientation: .portrait
        )
    }

    func testTimerElementCoversTheCountdownInLandscape() {
        assertDialElementsMatchRenderedReadout(contentSize: "UICTContentSizeCategoryL", orientation: .landscapeLeft)
    }

    private func assertDialElementsMatchRenderedReadout(
        contentSize: String, orientation: UIDeviceOrientation
    ) {
        continueAfterFailure = false
        let rendered = dialFrames(contentSize: contentSize, orientation: orientation, probe: true)
        let voiceOver = dialFrames(contentSize: contentSize, orientation: orientation, probe: false)
        let digits = rendered.readout
        // The two frames come from two launches. On a landscape iOS 18.6 SE
        // the digits' own frame reads up to 1.5 pt below the element that
        // holds them. The old substitute element missed by 60 pt or more.
        XCTAssertTrue(
            voiceOver.readout.insetBy(dx: -2, dy: -2).contains(digits),
            "the timer element \(voiceOver.readout) covers the rendered countdown \(digits)"
        )
        XCTAssertGreaterThanOrEqual(voiceOver.readout.height, 44, "the timer element is a usable touch target")
        XCTAssertEqual(voiceOver.progress.midX, rendered.progress.midX, accuracy: 1)
        XCTAssertEqual(voiceOver.progress.midY, rendered.progress.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(voiceOver.progress.width, rendered.progress.width - 1)
    }

    private func dialFrames(contentSize: String, orientation: UIDeviceOrientation, probe: Bool) -> DialFrames {
        XCUIDevice.shared.orientation = .portrait
        let environment = probe ? ["POMODOROUGH_UI_TEST_DIAL": "1"] : [:]
        let app = launchResetTestApplication(contentSize: contentSize, environment: environment)
        defer { app.terminate() }
        if orientation != .portrait { rotate(app, to: orientation) }
        let readout = probe
            ? app.staticTexts["AP08-countdown-digits"]
            : labelled("Focus timer", in: app)
        let progress = labelled("Pomodoro progress", in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let frames = DialFrames(readout: settledFrame(of: readout), progress: settledFrame(of: progress))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ios27-09-\(contentSize)-\(orientation.rawValue)-\(probe ? "probe" : "voiceover")"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return frames
    }

    /// The card animates into place after launch and rotation. A frame read
    /// mid-animation is a point or two off, so wait until two reads agree.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var frame = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let next = element.frame
            if next == frame { return frame }
            frame = next
        }
        XCTFail("\(element) never stopped moving")
        return frame
    }

    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [rotated], timeout: 10), .completed)
        // Let the landscape card settle before frames are read.
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
    }

    private func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
