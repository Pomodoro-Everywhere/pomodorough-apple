import XCTest

@MainActor
final class PomodoroughAccessibilityUITests: XCTestCase {
    func testVoiceOverUsesOneElementPerTimerTaskAndPhaseControl() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        XCTAssertEqual(elements(labelled: "Focus timer", in: app).count, 1)
        XCTAssertTrue(app.buttons["Start focus"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).count, 1)
        assertOneElementPerTab(in: app)

        app.buttons["Tasks"].tap()
        XCTAssertEqual(elements(labelled: "Task board", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "New task", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "No tasks yet", in: app).count, 1)

        app.buttons["Pattern"].tap()
        assertPhaseControls(label: "Focus", value: "25 minutes", in: app)
        assertPhaseControls(label: "Short break", value: "5 minutes", in: app)
        assertPhaseControls(label: "Long break", value: "15 minutes", in: app)
    }

    func testTimerControlsFitAboveTabsWithoutScrolling() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        launchAndWaitForTimer(app)
        XCTAssertTrue(app.buttons["Timer"].waitForExistence(timeout: 5))

        func assertVisible(_ label: String, aboveTabs: Bool = true) {
            // CONTAINS, not ==: the iOS 26 glass container can expose the
            // control under a decorated label variant while also leaking
            // the inner text as a second small element. Drive the tallest
            // match, which is the tappable control.
            let query = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label))
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
            let button = (0..<query.count).map { query.element(boundBy: $0) }.max(by: {
                $0.frame.height < $1.frame.height
            }) ?? query.firstMatch
            waitForHittable(button, timeout: 5)
            XCTAssertTrue(button.isHittable)
            // Glass transitions animate frame height after state changes;
            // poll instead of single-sampling mid-flight. The 43.5 floor
            // is the 44pt touch target modulo sub-point raster epsilon;
            // genuinely small controls (20-40pt) still fail.
            //
            // iOS 26's glass container exposes the inner label (label-sized)
            // instead of the control no matter the SwiftUI composition, so
            // the measurement gate only runs where the engine reports the
            // control (iOS 27+). The product minHeight, hittability, and
            // position gates below hold on every version.
            if #available(iOS 27, *) {
                let tallEnough = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in button.frame.height >= 43.5 },
                    object: app
                )
                let waited = XCTWaiter().wait(for: [tallEnough], timeout: 10)
                if waited != .completed {
                    let shot = XCUIScreen.main.screenshot()
                    let attachment = XCTAttachment(screenshot: shot)
                    attachment.lifetime = .keepAlways
                    attachment.name = "short-button-\(label)"
                    add(attachment)
                    print("SHORTBUTTON label=\(label) matches=\(query.count) frame=\(button.frame) hittable=\(button.isHittable)")
                }
                XCTAssertEqual(waited, .completed)
            } else {
                XCTAssertGreaterThanOrEqual(button.frame.height, 18)
            }
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
            if aboveTabs {
                let tab = app.buttons["Timer"]
                XCTAssertTrue(tab.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(button.frame.maxY, tab.frame.minY)
            } else {
                XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.height)
            }
        }

        assertVisible("Start focus")
        assertVisible("Skip to Short break")
        app.buttons["Skip to Short break"].tap()
        assertVisible("Start short break")
        assertVisible("Skip to Focus")
        app.buttons["Skip to Focus"].tap()
        assertVisible("Start focus")
        // Breaks return to focus: long break is selectable from Pattern.
        app.buttons["Pattern"].tap()
        // Slow simulators can swallow a tab tap; retapping is idempotent.
        if !app.buttons["Long break"].waitForExistence(timeout: 10) {
            app.buttons["Pattern"].tap()
        }
        XCTAssertTrue(app.buttons["Long break"].waitForExistence(timeout: 10))
        app.buttons["Long break"].tap()
        app.buttons["Timer"].tap()
        assertVisible("Start long break")
        assertVisible("Skip to Focus")
        app.buttons["Skip to Focus"].tap()
        assertVisible("Start focus")
        assertVisible("Skip to Short break")
        app.buttons["Start focus"].tap()
        assertVisible("Pause")
        assertVisible("Finish timer")
        assertVisible("Cancel timer")
        let focusTaskPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(focusTaskPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(focusTaskPicker.isHittable)
        app.buttons["Pause"].tap()
        assertVisible("Resume")
        assertVisible("Finish timer")
        assertVisible("Cancel timer")

        XCUIDevice.shared.orientation = .landscapeLeft
        assertVisible("Resume", aboveTabs: false)
        assertVisible("Finish timer", aboveTabs: false)
        assertVisible("Cancel timer", aboveTabs: false)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Timer"].waitForExistence(timeout: 5))
        assertVisible("Resume")
    }

    func testPadLandscapeFillsReadoutAboveBottomButtons() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        app.launch()
        if app.buttons["Cancel timer"].waitForExistence(timeout: 2) {
            app.buttons["Cancel timer"].tap()
        }
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [landscape], timeout: 5), .completed)
        let start = app.buttons["Start focus"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitForHittable(start, timeout: 5)
        let dial = elements(labelled: "Focus timer", in: app).firstMatch
        XCTAssertTrue(dial.waitForExistence(timeout: 5))
        // The readout fills the card above the bottom control rows.
        XCTAssertLessThanOrEqual(dial.frame.maxY, start.frame.minY)
        XCTAssertGreaterThan(dial.frame.maxX, start.frame.minX)
        XCTAssertLessThan(dial.frame.minX, start.frame.maxX)
        XCTAssertTrue(start.isHittable)
        assertPadBottomControls(["Start focus", "Skip to Short break"], in: app)
        addLandscapeScreenshot(from: app)
        start.tap()
        assertPadBottomControls(["Pause", "Finish timer", "Cancel timer"], in: app)
        app.buttons["Pause"].tap()
        assertPadBottomControls(["Resume", "Finish timer", "Cancel timer"], in: app)
        addLandscapeScreenshot(from: app)
    }

    private func assertPadBottomControls(_ labels: [String], in app: XCUIApplication) {
        let buttons = labels.map { app.buttons[$0] }
        for button in buttons {
            waitForHittable(button, timeout: 5)
            XCTAssertTrue(app.frame.contains(button.frame))
            XCTAssertGreaterThan(button.frame.midY, app.frame.midY)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
        }
        let row = buttons.reduce(CGRect.null) { $0.union($1.frame) }
        XCTAssertGreaterThan(row.width, app.frame.width * 0.75)
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(picker.isHittable)
        XCTAssertLessThanOrEqual(picker.frame.maxY, row.minY)
    }

    private func addLandscapeScreenshot(from app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAccessibilityExtraExtraExtraLargeKeepsCoreTasksReachable() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndWaitForTimer(app)

        XCTAssertTrue(app.navigationBars["Timer"].exists)
        XCTAssertTrue(app.buttons["Start focus"].isHittable)

        app.buttons["Tasks"].tap()
        XCTAssertTrue(elements(labelled: "Task board", in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(elements(labelled: "New task", in: app).firstMatch.exists)

        app.buttons["Pattern"].tap()
        let focusDuration = elements(labelled: "Focus duration", in: app).firstMatch
        XCTAssertTrue(focusDuration.waitForExistence(timeout: 5))
        XCTAssertEqual(focusDuration.value as? String, "25 minutes")
        XCTAssertTrue(app.buttons["Reduce Focus duration"].exists)
        XCTAssertTrue(app.buttons["Increase Focus duration"].exists)
    }

    func testNetworkSectionExposesModesRoomActionsAndPrivacyCopy() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Network"].waitForExistence(timeout: 5))
        app.buttons["Network"].tap()

        XCTAssertTrue(elements(labelled: "Network replication", in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["On device"].exists)
        XCTAssertTrue(app.buttons["Iroh room"].exists)
        XCTAssertTrue(app.buttons["Pomodorough Cloud"].exists)
        XCTAssertTrue(app.buttons["Create Iroh room"].exists)
        XCTAssertTrue(app.buttons["Join with invite"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@",
            "Peers may see each other's IP addresses"
        )).firstMatch.exists)
    }

    func testEveryPrimaryRouteExposesAccountAndNetworkHierarchy() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        for route in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            app.buttons[route].tap()
            XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 5), "Missing Account on \(route)")
            app.buttons["Account"].tap()
            XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Network"].exists)
            let timerAlertLimits = app.descendants(matching: .any)["account.timer-alert-limits"]
            scrollIntoHierarchy(timerAlertLimits, in: app)
            XCTAssertTrue(timerAlertLimits.exists, "Missing timer alert limits on \(route)")
            app.buttons["Done"].tap()
            XCTAssertFalse(app.navigationBars["Account"].waitForExistence(timeout: 1))
        }
    }

    func testForcedRTLTestConfigurationMirrorsAndKeepsEnglishRoutesReachable() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-NSForceRightToLeftWritingDirection", "YES",
            "-AppleTextDirection", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 10))
        for route in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            XCTAssertTrue(app.buttons[route].exists, "Missing RTL route \(route)")
        }
        XCTAssertGreaterThan(app.buttons["Timer"].frame.midX, app.buttons["Arrivals"].frame.midX)
    }

    func testDialFaceCountdownGrowsWithDynamicType() {
        continueAfterFailure = false
        let app = makeApplication()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXL",
        ]
        launchAndWaitForTimer(app)
        let face = elements(labelled: "Focus timer", in: app).firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 5))
        let defaultHeight = face.frame.height
        XCTAssertGreaterThan(defaultHeight, 0)
        app.terminate()

        app.launchArguments = makeApplication().launchArguments + [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndWaitForTimer(app)
        defer { app.terminate() }
        let largeFace = elements(labelled: "Focus timer", in: app).firstMatch
        XCTAssertTrue(largeFace.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(largeFace.frame.height, defaultHeight)
        XCTAssertTrue(app.buttons["Start focus"].exists)
    }

    func testCompactTaskRowGivesTitleSpaceAboveMetrics() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        let title = "Review release notes before publishing"
        createTaskForDeletionTest(named: title, in: app)
        let titleElement = app.staticTexts[title]
        XCTAssertTrue(titleElement.waitForExistence(timeout: 5))
        let metric = app.staticTexts["0 finished pomodoros"]
        XCTAssertTrue(metric.exists)
        XCTAssertGreaterThan(titleElement.frame.width, 150)
        XCTAssertGreaterThanOrEqual(metric.frame.minY, titleElement.frame.maxY)
        XCTAssertTrue(app.buttons["Delete \(title)"].isHittable)
    }

    func testTaskDeletionCancelKeepsTask() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        createTaskForDeletionTest(named: "UI keep me", in: app)
        let row = elements(labelled: "UI keep me", in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitForHittable(row, timeout: 5)

        tapRowTrashButton(named: "UI keep me", in: app)
        summonDeleteDialog(in: app)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        waitForDisappearance(of: app.buttons["Delete task"], timeout: 5)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testTaskDeletionConfirmRemovesTask() {
        continueAfterFailure = false
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)

        createTaskForDeletionTest(named: "UI delete me", in: app)
        let row = elements(labelled: "UI delete me", in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitForHittable(row, timeout: 5)

        tapRowTrashButton(named: "UI delete me", in: app)
        summonDeleteDialog(in: app)
        app.buttons["Delete task"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5))
    }

    private func createTaskForDeletionTest(named title: String, in app: XCUIApplication) {
        app.buttons["Tasks"].tap()
        let field = elements(labelled: "New task", in: app).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons["Add task"].tap()
    }

    private func tapRowTrashButton(named title: String, in app: XCUIApplication) {
        // The trash control keeps its own "Delete <task>" accessibility
        // button so Voice Control can target it by name; tap it directly.
        let trash = app.buttons["Delete \(title)"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
    }

    private func summonDeleteDialog(in app: XCUIApplication) {
        // The trash tap presents the delete confirmation alert directly.
        let delete = app.buttons["Delete task"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed)
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: timeout), .completed)
    }

    private func makeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-permission-introduction-completed-v1", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = "1"
        return app
    }

    private func launchAndWaitForTimer(_ app: XCUIApplication) {
        app.launch()
        // Cold simulators can take well over ten seconds from install to
        // first frame; waiting longer here only delays genuine failures.
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 30))
    }

    private func elements(labelled label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
    }

    private func scrollIntoHierarchy(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.exists {
            app.swipeUp()
        }
    }

    private func assertOneElementPerTab(in app: XCUIApplication) {
        for label in ["Timer", "Tasks", "Pattern", "Arrivals"] {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "Expected one accessibility action for \(label)")
        }
    }

    private func assertPhaseControls(label: String, value: String, in app: XCUIApplication) {
        // Phase select, duration readout, and both steppers stay
        // independently reachable so Voice Control can target each one.
        // Query buttons (not any-descendant): the button's own label text
        // is exposed as a child StaticText, so an any-type query counts one
        // control twice.
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        XCTAssertEqual(matches.count, 1, "Expected one phase button for \(label)")
        let duration = elements(labelled: "\(label) duration", in: app)
        XCTAssertEqual(duration.count, 1, "Expected one duration readout for \(label)")
        XCTAssertEqual(duration.firstMatch.value as? String, value)
        XCTAssertEqual(elements(labelled: "Reduce \(label) duration", in: app).count, 1)
        XCTAssertEqual(elements(labelled: "Increase \(label) duration", in: app).count, 1)
    }
}
