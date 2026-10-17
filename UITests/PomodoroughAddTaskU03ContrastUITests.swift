import XCTest
import UIKit

// R49-U03: Add task keeps fill-derived foreground on newer SDKs.
// The prominent style resolves the shorthand label color from the
// button level on some SDKs, so the fix carries the same foreground
// on the inner Label and the button. These rendered pins assert the
// enabled button clears 4.5:1 in the matrix light/dark appearances
// at standard and XXXL sizes, keep U01/U02 controls, and pin the
// old white-on-signal pair as the sub-4.5 baseline.
@MainActor
final class PomodoroughAddTaskU03ContrastUITests: XCTestCase {
    func testU03AddTaskStandardContrast() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeU03App(contentSize: "UICTContentSizeCategoryL")
        defer { app.terminate() }
        launchU03(app)
        openU03Composer(app)
        assertU03AddDisabled(app)
        fillU03Title("R49 U03 standard", app: app)
        try measureU03Contrast(state: "standard", app: app)
        submitU03Title("R49 U03 standard", app: app)
    }

    func testU03AddTaskXXXLContrast() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeU03App(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        launchU03(app)
        openU03Composer(app)
        assertU03AddDisabled(app)
        fillU03Title("R49 U03 XXXL", app: app)
        try measureU03Contrast(state: "xxxl", app: app)
        submitU03Title("R49 U03 XXXL", app: app)
    }

    func testU03WhiteOnSignalBaselineIsRed() {
        let white = u03Luminance(rgb: 0xFFFFFF)
        let black = u03Luminance(rgb: 0x000000)
        let fill = u03Luminance(rgb: 0xFF604F)
        let whiteRatio = (max(white, fill) + 0.05) / (min(white, fill) + 0.05)
        let blackRatio = (max(black, fill) + 0.05) / (min(black, fill) + 0.05)
        XCTAssertLessThan(whiteRatio, 4.5, "Old white-on-signal must fail")
        XCTAssertEqual(whiteRatio, 2.98378, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(blackRatio, 4.5)
        XCTAssertEqual(blackRatio, 7.03805, accuracy: 0.01)
    }

    func testU03U01U02ControlsPreserved() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeU03App(contentSize: nil)
        defer { app.terminate() }
        launchU03(app)
        let start = app.buttons["Start focus"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.buttons["Skip to Short break"].exists)
        openU03Composer(app)
        assertU03AddDisabled(app)
    }

    private func makeU03App(contentSize: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        return app
    }

    private func launchU03(_ app: XCUIApplication) {
        app.launch()
        if app.buttons["Start focus"].waitForExistence(timeout: 30) { return }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    }

    private func openU03Composer(_ app: XCUIApplication) {
        app.buttons["Tasks"].tap()
        let field = u03Elements(labelled: "New task", in: app).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
    }

    private func assertU03AddDisabled(_ app: XCUIApplication) {
        let add = app.buttons["Add task"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(add.isEnabled, "Empty title keeps Add disabled")
    }

    private func fillU03Title(_ title: String, app: XCUIApplication) {
        let field = u03Elements(labelled: "New task", in: app).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        let add = app.buttons["Add task"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isEnabled)
        XCTAssertTrue(add.isHittable)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10))
    }

    @discardableResult
    private func measureU03Contrast(state: String, app: XCUIApplication) throws -> UInt32 {
        let button = app.buttons["Add task"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(app.frame.contains(frame))
        let shot = XCUIScreen.main.screenshot()
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        let sample = crop.insetBy(dx: crop.width * 0.25, dy: crop.height * 0.25).integral
        XCTAssertGreaterThan(sample.width, 0)
        XCTAssertGreaterThan(sample.height, 0)
        let pixels = try u03Histogram(try XCTUnwrap(image.cropping(to: sample)))
        let colors = pixels.sorted { $0.value > $1.value }
        XCTAssertGreaterThanOrEqual(colors.count, 2)
        let fill = try XCTUnwrap(colors.first)
        let fillLuminance = u03Luminance(rgb: fill.key)
        var foreground = try XCTUnwrap(colors.dropFirst().first)
        var ratio = 0.0
        for candidate in colors.dropFirst() where candidate.value > 30 {
            let ordered = [fillLuminance, u03Luminance(rgb: candidate.key)].sorted()
            let candidateRatio = (ordered[1] + 0.05) / (ordered[0] + 0.05)
            if candidateRatio > ratio {
                ratio = candidateRatio
                foreground = candidate
            }
        }
        attachU03(name: "R49-U03-\(state)", app: app)
        XCTAssertGreaterThan(fill.value, Int(sample.width * sample.height) / 3)
        XCTAssertGreaterThan(foreground.value, 30)
        XCTAssertGreaterThan(ratio, 0)
        let receipt = "R49_U03_PIXELS state=\(state) frame=\(frame) crop=\(crop) sample=\(sample) foreground=\(String(foreground.key, radix: 16)) foregroundPixels=\(foreground.value) fill=\(String(fill.key, radix: 16)) fillPixels=\(fill.value) contrast=\(ratio)"
        print(receipt)
        add(XCTAttachment(string: receipt))
        XCTAssertGreaterThanOrEqual(ratio, 4.5, receipt)
        return foreground.key
    }

    private func submitU03Title(_ title: String, app: XCUIApplication) {
        app.buttons["Add task"].tap()
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(matches.count, 1, "Add creates exactly one task")
        let field = u03Elements(labelled: "New task", in: app).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let cleared = field.value as? String ?? ""
        XCTAssertTrue(cleared == "" || cleared == "Write release notes")
        XCTAssertFalse(app.buttons["Add task"].isEnabled)
    }

    private func u03Histogram(_ image: CGImage) throws -> [UInt32: Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var histogram: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[offset + 3], 255)
            let rgb = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
            histogram[rgb, default: 0] += 1
        }
        return histogram
    }

    private func u03Luminance(rgb: UInt32) -> Double {
        let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)]
        let linear = channels.map { channel in
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func u03Elements(labelled label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
    }

    private func attachU03(name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
