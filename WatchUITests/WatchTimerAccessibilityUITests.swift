import UIKit
import XCTest

/// WCH-02, WCH-03 and WCH-04 on a watch simulator with no paired iPhone, so
/// the phone is unreachable and the timer comes from the seeded cache.
@MainActor
final class WatchTimerAccessibilityUITests: XCTestCase {
    private let largestTextSize = "UICTContentSizeCategoryAccessibilityXXXL"

    /// WCH-04: VoiceOver frames Pause and Finish as the visible 44 pt controls.
    func testPauseAndFinishAccessibilityFramesCoverTheVisibleControls() throws {
        let app = try launch(snapshot: .running)
        let pause = app.buttons["Pause"]
        let finish = app.buttons["Finish timer"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(finish.exists)
        attachScreenshot(app, named: "wch04-running")
        for (name, frame) in [("Pause", pause.frame), ("Finish timer", finish.frame)] {
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(name) frame \(frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(name) frame \(frame)")
        }
        XCTAssertGreaterThan(pause.frame.width, finish.frame.width, "Pause is the wide capsule")
    }

    /// WCH-03: the unreachable phone is named in words above the timer, not
    /// only by a grey dot.
    func testUnreachablePhoneIsNamedAboveTheCachedTimer() throws {
        let app = try launch(snapshot: .running)
        let notice = app.descendants(matching: .any)["iPhone unreachable, showing last synced timer"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        attachScreenshot(app, named: "wch03-unreachable")
        let dial = app.descendants(matching: .any)["Focus, Running"]
        XCTAssertTrue(dial.exists)
        XCTAssertGreaterThanOrEqual(notice.frame.width, 40, "notice frame \(notice.frame)")
        XCTAssertGreaterThanOrEqual(notice.frame.height, 10, "notice frame \(notice.frame)")
        XCTAssertLessThanOrEqual(notice.frame.maxY, dial.frame.minY + 1, "notice sits above the dial")
    }

    /// WCH-02: at the largest text size on the 40 mm watch, "Try again"
    /// can be reached without a phone, and the message stays on the screen.
    func testTryAgainIsReachableAtTheLargestTextSize() throws {
        let app = try launch(snapshot: nil, textSize: largestTextSize)
        let tryAgain = app.buttons["Try again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 10))
        attachScreenshot(app, named: "wch02-no-phone-axxxl")
        let message = app.staticTexts["Open Pomodorough on iPhone"]
        XCTAssertTrue(message.exists)
        XCTAssertGreaterThanOrEqual(message.frame.minX, app.frame.minX, "message frame \(message.frame)")
        XCTAssertLessThanOrEqual(message.frame.maxX, app.frame.maxX, "message frame \(message.frame)")
        scrollUntilVisible(tryAgain, in: app)
        attachScreenshot(app, named: "wch02-no-phone-axxxl-scrolled")
        XCTAssertTrue(isFullyVisible(tryAgain, in: app), "Try again \(tryAgain.frame) in \(app.frame)")
    }

    /// WCH-02: at the largest text size on the 40 mm watch, "Pomodorough"
    /// does not break in the middle. Kept whole, the message takes three
    /// lines ("Open", "Pomodorough", "on iPhone"). A plain wrapping text
    /// hyphenates the name instead ("Pomodor-", "ough on") and takes four,
    /// because "Open Pomo-" does not fit on one line either. XCUI exposes
    /// no line count, so the test counts the rows of white text in a
    /// screenshot of the message.
    func testPhoneMessageKeepsPomodoroughWholeAtTheLargestTextSize() throws {
        let app = try launch(snapshot: nil, textSize: largestTextSize)
        let message = app.staticTexts["Open Pomodorough on iPhone"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        scrollUntilVisible(message, in: app)
        attachScreenshot(app, named: "wch02-message-axxxl")
        let lines = try XCTUnwrap(TextLineCounter.lineCount(of: message.frame, in: app))
        XCTAssertTrue((2...3).contains(lines), "message \(message.frame) shows \(lines) lines")
    }

    /// WCH-02: at the largest text size the paused timer's dial ends above
    /// Resume, the controls stack, and Resume and Finish stay reachable by
    /// scrolling. The screenshots show the countdown and the status inside
    /// the ring; the dial ignores its children for VoiceOver, so its text
    /// frames cannot be read here (WatchDialLayoutTests covers them).
    func testPausedControlsAreReachableAtTheLargestTextSize() throws {
        let app = try launch(snapshot: .paused, textSize: largestTextSize)
        let dial = app.descendants(matching: .any)["Focus, Paused"]
        XCTAssertTrue(dial.waitForExistence(timeout: 10))
        attachScreenshot(app, named: "wch02-paused-axxxl")
        XCTAssertEqual(dial.value as? String, "100:00 remaining")
        let resume = app.buttons["Resume"]
        let finish = app.buttons["Finish timer"]
        XCTAssertLessThanOrEqual(dial.frame.maxY, resume.frame.minY + 0.5, "dial \(dial.frame) over Resume \(resume.frame)")
        XCTAssertLessThanOrEqual(resume.frame.maxY, finish.frame.minY + 0.5, "controls must stack at this text size")
        scrollUntilVisible(resume, in: app)
        XCTAssertTrue(isFullyVisible(resume, in: app), "Resume \(resume.frame) in \(app.frame)")
        scrollUntilVisible(finish, in: app)
        attachScreenshot(app, named: "wch02-paused-axxxl-scrolled")
        XCTAssertTrue(isFullyVisible(finish, in: app), "Finish \(finish.frame) in \(app.frame)")
    }

    private func launch(snapshot: SeededTimer?, textSize: String? = nil) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // A string value is not Data, so the app sees no cached snapshot.
        let cachedSnapshot = try snapshot?.plistData() ?? "none"
        app.launchArguments += ["-watch-timer-snapshot", cachedSnapshot]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launchEnvironment["POMODOROUGH_SILENCE_AUDIO"] = "1"
        app.launch()
        return app
    }

    /// A control cut by the screen edge can still be hittable at its
    /// centre, so reachable here means the whole frame is on screen.
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !isFullyVisible(element, in: app) {
            app.swipeUp()
        }
    }

    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        element.isHittable && app.frame.insetBy(dx: -0.5, dy: -0.5).contains(element.frame)
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Counts lines of light text on the black watch background: each run of
/// screenshot rows that holds a bright pixel is one line. Letters with
/// ascenders and capitals join the dot of "i" to its line.
private enum TextLineCounter {
    @MainActor
    static func lineCount(of frame: CGRect, in app: XCUIApplication) -> Int? {
        guard let screen = app.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(screen.width) / app.frame.width
        let region = frame.offsetBy(dx: -app.frame.minX, dy: -app.frame.minY)
        let pixels = CGRect(
            x: region.minX * scale, y: region.minY * scale,
            width: region.width * scale, height: region.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard let text = screen.cropping(to: pixels) else { return nil }
        return inkRuns(in: grayscale(text), width: text.width)
    }

    private static func grayscale(_ image: CGImage) -> [UInt8] {
        var gray = [UInt8](repeating: 0, count: image.width * image.height)
        gray.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return gray
    }

    /// Anti-aliased edges stay below half brightness, so the gap between
    /// two lines counts as background.
    private static func inkRuns(in gray: [UInt8], width: Int) -> Int {
        guard width > 0 else { return 0 }
        var runs = 0
        var previousRowHasInk = false
        for rowStart in stride(from: 0, to: gray.count, by: width) {
            let hasInk = gray[rowStart..<rowStart + width].contains { $0 > 127 }
            if hasInk && !previousRowHasInk { runs += 1 }
            previousRowHasInk = hasInk
        }
        return runs
    }
}

/// A cached timer in the shape WatchSyncService stores: JSONEncoder output
/// with dates as seconds since the reference date.
private enum SeededTimer {
    case running
    case paused

    func plistData() throws -> String {
        let now = Date().timeIntervalSinceReferenceDate
        let json: [String: Any] = [
            "phase": "focus",
            "status": self == .running ? "running" : "paused",
            "sequence": 1,
            "timerId": "watch-ui-test-timer",
            "plannedDurationMs": 6_000_000,
            "elapsedAtAnchorMs": self == .running ? 60_000 : 0,
            "anchorAt": now,
            "selectedPhase": "focus",
            "focusDurationMs": 6_000_000,
            "shortBreakDurationMs": 300_000,
            "longBreakDurationMs": 900_000,
            "updatedAt": now,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }
}
