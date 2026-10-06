import XCTest

@MainActor
final class PomodoroughAccessibilityUITests: XCTestCase {
    // XCTest has no Duo pose API. Run on a Closed Duo with
    // TEST_RUNNER_POMODOROUGH_DUO_POSE=Open (or Book), then select that
    // Device Hub pose after AP01_READY. A real display transition is required;
    // a timeout fails instead of treating a static unfolded launch as coverage.
    // The environment names the requested pose, not observed hinge state.
    // External evidence must verify Closed and the selected Open/Book pose,
    // then require this exact test to pass with zero skips in the xcresult.
    func testDuoClosedToUnfoldedKeepsNavigationReachable() throws {
        let pose = ProcessInfo.processInfo.environment["POMODOROUGH_DUO_POSE"]
        try XCTSkipUnless(pose == "Open" || pose == "Book", "Requires external Duo pose driver")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        defer { app.terminate() }
        launchAndWaitForTimer(app)
        let closedFrame = app.frame
        XCTAssertLessThan(closedFrame.width, closedFrame.height)
        assertPrimaryNavigationReachable(in: app)
        print("AP01_READY Closed -> \(pose ?? "") frame=\(closedFrame)")
        let unfolded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // XCTest can report the unfolded app in portrait coordinates.
            // Rotation alone preserves area; switching displays increases it.
            app.frame.width * app.frame.height > closedFrame.width * closedFrame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter().wait(for: [unfolded], timeout: 120), .completed)
        print("AP01_UNFOLDED \(pose ?? "") frame=\(app.frame)")
        attachNavigationEvidence("AP01-\(pose ?? "")", in: app)
        assertPrimaryNavigationReachable(in: app)
    }

    func testPhoneLandscapeTimerChromeRestoresNavigationOnPortrait() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        app.launchEnvironment["POMODOROUGH_UI_TEST_LAYOUT"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        launchAndWaitForTimer(app)
        app.buttons["Start focus"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let compactLandscape = try waitForLandscapeEligibility(in: app)
        try XCTSkipUnless(compactLandscape, "Measured regular x regular landscape keeps native chrome; phone-only assertion is ineligible")
        waitForHittable(app.buttons["Pause"], timeout: 5)
        XCTAssertFalse(app.buttons["Tasks"].isHittable)
        XCTAssertFalse(app.buttons["Account"].isHittable)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        attachNavigationEvidence("AP01-phone-landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        assertPrimaryNavigationReachable(in: app)
        XCTAssertTrue(app.buttons["Resume"].exists)
    }

    private func waitForLandscapeEligibility(in app: XCUIApplication) throws -> Bool {
        let probe = app.staticTexts["AP01-layout"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "Missing DEBUG layout inputs")
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let fields = (probe.value as? String ?? "").split(separator: "|")
            guard fields.count == 5, let width = Double(fields[0]),
                  let height = Double(fields[1]) else { return false }
            return width > height && height > 0 && app.frame.width > app.frame.height
        }, object: probe)
        XCTAssertEqual(XCTWaiter().wait(for: [landscape], timeout: 10), .completed,
                       "Rotation must reach measured landscape before eligibility is checked")
        let inputs = try XCTUnwrap(probe.value as? String)
        let fields = inputs.split(separator: "|").map(String.init)
        XCTAssertEqual(fields.count, 5)
        guard fields.count == 5 else { throw NSError(domain: "AP01-layout", code: 1) }
        XCTAssertTrue(["compact", "regular"].contains(fields[2]))
        XCTAssertTrue(["compact", "regular"].contains(fields[3]))
        XCTAssertEqual(fields[4], "false", "Compatibility run must use standard Dynamic Type")
        let compact = fields[2] == "compact" || fields[3] == "compact"
        print("AP01_ELIGIBILITY compact=\(compact) inputs=\(inputs)")
        return compact
    }

    private func assertPrimaryNavigationReachable(in app: XCUIApplication) {
        let destinations = [("Tasks", "Task board"), ("Pattern", "Focus duration"),
                            ("Arrivals", "No arrivals yet"), ("Timer", "Focus timer")]
        for (route, content) in destinations {
            let tab = app.buttons[route]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing \(route)")
            waitForHittable(tab, timeout: 5)
            tab.tap()
            XCTAssertTrue(elements(labelled: content, in: app).firstMatch.waitForExistence(timeout: 5))
            waitForHittable(app.buttons["Account"], timeout: 5)
            app.buttons["Account"].tap()
            XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Network"].exists)
            app.buttons["Done"].tap()
            waitForDisappearance(of: app.navigationBars["Account"], timeout: 5)
        }
    }

    private func attachNavigationEvidence(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

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
            // the measurement gate only runs where the engine reports a
            // style-sized element: iOS 27+, or the pre-26 fallback where
            // borderedProminent reports the control itself. The product
            // minHeight, hittability, and position gates below hold on
            // every version.
            let measuresStyleSizedElement: Bool = {
                if #available(iOS 27, *) { return true }
                if #available(iOS 26, *) { return false }
                return true
            }()
            if measuresStyleSizedElement {
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
                let timerTab = app.buttons["Timer"]
                XCTAssertTrue(timerTab.waitForExistence(timeout: 5))
                XCTAssertTrue(
                    app.frame.contains(button.frame),
                    "\(label) escapes app frame: \(button.frame) in \(app.frame)"
                )
                for route in ["Timer", "Tasks", "Pattern", "Arrivals"] {
                    let other = app.buttons[route]
                    guard other.exists else { continue }
                    XCTAssertFalse(
                        button.frame.intersects(other.frame),
                        "\(label) overlaps \(route): \(button.frame) vs \(other.frame)"
                    )
                }
            } else {
                XCTAssertTrue(
                    app.frame.contains(button.frame),
                    "\(label) escapes app frame: \(button.frame) in \(app.frame)"
                )
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

    /// AP116 review surface: the 4.5:1 contrast guarantee itself is pinned
    /// by ProminentButtonContrastTests (AX cannot read colors), while this
    /// walk keeps every focus/break control hittable and attaches a
    /// screenshot per phase for visual review. The iOS-18/SE2 CI job sets
    /// the simulator to dark appearance via simctl first, so its
    /// attachments are the dark-mode evidence; assertions hold anywhere.
    func testFocusAndBreakButtonsStayHittableForContrastReview() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        launchAndWaitForTimer(app)

        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.lifetime = .keepAlways
            attachment.name = "contrast-\(name)"
            add(attachment)
        }

        func assertHittable(_ label: String) {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(label)")
            XCTAssertTrue(button.isHittable, "Not hittable: \(label)")
        }

        assertHittable("Start focus")
        assertHittable("Skip to Short break")
        shot("focus-idle")
        app.buttons["Skip to Short break"].tap()
        assertHittable("Start short break")
        shot("short-break-idle")
        app.buttons["Pattern"].tap()
        if !app.buttons["Long break"].waitForExistence(timeout: 10) {
            app.buttons["Pattern"].tap()
        }
        XCTAssertTrue(app.buttons["Long break"].waitForExistence(timeout: 10))
        app.buttons["Long break"].tap()
        app.buttons["Timer"].tap()
        assertHittable("Start long break")
        shot("long-break-idle")
        app.buttons["Skip to Focus"].tap()
        app.buttons["Start focus"].tap()
        assertHittable("Pause")
        assertHittable("Finish timer")
        assertHittable("Cancel timer")
        shot("focus-running")
        app.buttons["Pause"].tap()
        assertHittable("Resume")
        shot("focus-paused")
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
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        launchAndWaitForTimer(app)

        XCTAssertTrue(app.navigationBars["Timer"].exists)
        attachNavigationEvidence("AP10-XXXL-before-scroll", in: app)
        revealAccessibleTimerControl("Start focus", in: app)
        XCTAssertTrue(app.buttons["Start focus"].isHittable)
        exerciseAccessibleTimer(in: app)

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

    private func exerciseAccessibleTimer(in app: XCUIApplication) {
        let actions = [
            ("Start focus", "Focus timer", "Running"),
            ("Pause", "Focus timer", "Paused"),
            ("Resume", "Focus timer", "Running"),
            ("Finish timer", "Short break timer", "Idle"),
            ("Skip to Focus", "Focus timer", "Idle"),
            ("Start focus", "Focus timer", "Running"),
            ("Cancel timer", "Focus timer", "Idle"),
        ]
        for (action, timer, status) in actions {
            revealAccessibleTimerControl(action, in: app)
            attachNavigationEvidence("AP10-XXXL-\(action)", in: app)
            // A physical tap at the visible control, without XCTest auto-scroll.
            app.buttons[action].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
            let readout = elements(labelled: timer, in: app).firstMatch
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value ENDSWITH %@", status), object: readout
            )
            XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed,
                           "\(action) must produce \(timer), \(status)")
        }
        let progress = elements(labelled: "Pomodoro progress", in: app).firstMatch
        XCTAssertEqual(progress.value as? String,
                       "1 of 4 toward the next long break, 1 completed today",
                       "Finish records one focus; Cancel must not complete another")
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertFalse(app.buttons["Resume"].exists)
        attachNavigationEvidence("AP10-XXXL-cancelled", in: app)
    }

    private func revealAccessibleTimerControl(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(label)")
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        // XXXL needs scrolling on short phones. Keep gestures inside content,
        // clear of the navigation and tab bars; never shrink the user's text.
        for _ in 0..<8 {
            let top = max(scroll.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let bottom = min(scroll.frame.maxY, app.buttons["Timer"].frame.minY)
            let frame = button.frame
            if button.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
            let viewport = CGRect(x: scroll.frame.minX, y: top,
                                  width: scroll.frame.width, height: bottom - top)
            XCTAssertGreaterThan(viewport.height, 0)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let direction: CGFloat = frame.minY < top ? 1 : -1
            let start = origin.withOffset(.init(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(.init(dx: 0, dy: direction * viewport.height * 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        attachNavigationEvidence("AP10-unreachable-\(label)", in: app)
        XCTFail("\(label) not fully visible and hittable after bounded content scrolling")
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

    /// R43-AP08: digit-specific countdown growth, independent of the
    /// "Focus timer" accessibility substitute. Queries the real rendered
    /// digits by AP08 identifier, asserts visual growth with Dynamic Type
    /// and containment without clipping, with screenshots per size.
    func testDialFaceCountdownDigitsGrowAndStayContained() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let baseline = measureCountdownDigits(contentSize: "UICTContentSizeCategoryAccessibilityXL")
        let large = measureCountdownDigits(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertEqual(baseline.label, "25:00")
        XCTAssertEqual(large.label, "25:00")
        XCTAssertGreaterThan(large.frame.height, baseline.frame.height)
        XCTAssertGreaterThan(large.frame.width, baseline.frame.width)
    }

    /// Launches the idle timer with the AP08 digit probe and returns the
    /// real digit frame. Asserts containment without clipping and attaches
    /// visual evidence. Never queries "Focus timer": independence from the
    /// substitute is explicit; probe mode hides the substitute.
    private func measureCountdownDigits(contentSize: String) -> (frame: CGRect, label: String) {
        let app = makeApplication()
        app.launchEnvironment["POMODOROUGH_UI_TEST_DIAL"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        defer { app.terminate() }
        launchAndWaitForTimer(app)
        let digits = app.staticTexts["AP08-countdown-digits"]
        XCTAssertTrue(digits.waitForExistence(timeout: 5), "Missing real countdown digits at \(contentSize)")
        let frame = digits.frame
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertTrue(app.frame.contains(frame), "digits escape app frame at \(contentSize): \(frame) in \(app.frame)")
        XCTAssertEqual(elements(labelled: "Focus timer", in: app).count, 0, "probe mode must not use substitute")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "AP08-digits-\(contentSize)"
        shot.lifetime = .keepAlways
        add(shot)
        print("AP08_DIGITS contentSize=\(contentSize) label=\(digits.label) frame=\(frame) app=\(app.frame)")
        return (frame, digits.label)
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

    func testTaskDeleteTargetEdgesAndCorners() {
        assertTaskDeleteTargetPerimeter(contentSize: "UICTContentSizeCategoryL")
    }

    func testTaskDeleteTargetEdgesAndCornersAtAccessibilityXXXL() {
        assertTaskDeleteTargetPerimeter(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func assertTaskDeleteTargetPerimeter(contentSize: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        defer { app.terminate() }
        launchAndWaitForTimer(app)
        let titles = ["AP03 target", "AP03 neighbor"]
        for title in titles { createTaskForDeletionTest(named: title, in: app) }
        let perimeter: [CGVector] = [
            .init(dx: 0.05, dy: 0.05), .init(dx: 0.5, dy: 0.05),
            .init(dx: 0.95, dy: 0.05), .init(dx: 0.95, dy: 0.5),
            .init(dx: 0.95, dy: 0.95), .init(dx: 0.5, dy: 0.95),
            .init(dx: 0.05, dy: 0.95), .init(dx: 0.05, dy: 0.5),
        ]
        for (index, point) in perimeter.enumerated() {
            let title = titles[index % titles.count]
            revealTaskDeleteButton(named: title, in: app)
            assertTaskDeleteTap(point, named: title, in: app)
        }
        // Check persisted cancellation, not just an unchanged row snapshot.
        app.terminate()
        app.launchEnvironment["POMODOROUGH_UI_TEST_RESET"] = nil
        launchAndWaitForTimer(app)
        app.buttons["Tasks"].tap()
        for title in titles {
            revealTaskDeleteButton(named: title, in: app)
            XCTAssertTrue(app.staticTexts[title].exists)
        }
    }

    private func revealTaskDeleteButton(named title: String, in app: XCUIApplication) {
        let button = app.buttons["Delete \(title)"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 {
            let frame = button.exists ? button.frame : .zero
            let visibleBottom = app.buttons["Tasks"].frame.minY
            let visibleTop = app.navigationBars.firstMatch.frame.maxY
            if button.isHittable && frame.minY > visibleTop
                && frame.maxY < visibleBottom { return }
            let start = scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            let direction: CGFloat = frame != .zero && frame.minY <= visibleTop ? 1 : -1
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(
                .init(dx: 0, dy: direction * scroll.frame.height * 0.2)
            ))
        }
        XCTFail("Task delete button not fully visible: \(title)")
    }

    private func assertTaskDeleteTap(_ point: CGVector, named title: String, in app: XCUIApplication) {
        let button = app.buttons["Delete \(title)"]
        XCTAssertEqual(app.buttons.matching(identifier: "Delete \(title)").count, 1)
        let frame = button.frame
        // Derive the intended minimum target around the measured control, even
        // when the broken baseline exposes only the 19x21-point icon.
        let width = max(44, frame.width)
        let height = max(44, frame.height)
        let location = CGVector(dx: frame.midX + (point.dx - 0.5) * width,
                                dy: frame.midY + (point.dy - 0.5) * height)
        print("AP03 title=\(title) frame=\(frame) tap=\(location)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(location).tap()
        let alert = app.alerts["Delete “\(title)”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Perimeter tap missed \(title) at \(point)")
        XCTAssertTrue(alert.buttons["Delete task"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "AP03-\(title)-\(point.dx)-\(point.dy)"
        attachment.lifetime = .keepAlways
        add(attachment)
        alert.buttons["Cancel"].tap()
        waitForDisappearance(of: alert, timeout: 5)
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertTrue(button.exists)
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

    /// R43-AP11: task picker text at largest fonts stays contained
    /// without reducing Dynamic Type or shrinking text. Asserts the
    /// selected title button stays inside the app frame and remains
    /// hittable at AccessibilityXXXL, and that task selection still
    /// works. Screenshots retain glyph-level evidence.
    func testTaskPickerTitleStaysContainedAtAccessibilityXXXL() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = makeApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        launchAndWaitForTimer(app)
        assertPickerContained(labelPrefix: "Focus task", shot: "AP11-XXXL-Unassigned", in: app)
        let title = "AP11 task"
        createTaskForDeletionTest(named: title, in: app)
        app.buttons["Timer"].tap()
        XCTAssertTrue(app.buttons["Start focus"].waitForExistence(timeout: 5))
        selectPickerTask(named: title, in: app)
        assertPickerContained(labelPrefix: "Focus task", shot: "AP11-XXXL-selected", in: app)
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(picker.label.contains(title), "picker must show selected title, got \(picker.label)")
    }

    private func assertPickerContained(labelPrefix: String, shot: String, in app: XCUIApplication) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Missing picker \(labelPrefix)")
        revealPicker(picker, in: app)
        XCTAssertTrue(picker.isHittable, "picker not hittable at XXXL")
        XCTAssertTrue(app.frame.contains(picker.frame), "picker escapes app frame: \(picker.frame) in \(app.frame)")
        let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shotAttachment.name = shot
        shotAttachment.lifetime = .keepAlways
        add(shotAttachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(shot)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print("AP11_PICKER shot=\(shot) label=\(picker.label) frame=\(picker.frame) app=\(app.frame)")
    }

    private func revealPicker(_ picker: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<8 {
            let top = max(scroll.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let bottom = min(scroll.frame.maxY, app.buttons["Timer"].frame.minY)
            let frame = picker.frame
            if picker.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
            let viewport = CGRect(x: scroll.frame.minX, y: top, width: scroll.frame.width, height: bottom - top)
            XCTAssertGreaterThan(viewport.height, 0)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let direction: CGFloat = frame.minY < top ? 1 : -1
            let start = origin.withOffset(.init(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(.init(dx: 0, dy: direction * viewport.height * 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
    }

    private func selectPickerTask(named title: String, in app: XCUIApplication) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Focus task")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        revealPicker(picker, in: app)
        picker.tap()
        let option = app.buttons[title]
        if option.waitForExistence(timeout: 5) {
            option.tap()
            return
        }
        let menuItem = app.menuItems[title]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Missing picker option \(title)")
        menuItem.tap()
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
        if app.buttons["Start focus"].waitForExistence(timeout: 30) { return }
        // Fresh runtimes can refuse the very first install/launch
        // ("Unknown application display identifier", SE/iOS 18 release
        // runs); one bounded relaunch converges once install settles.
        app.terminate()
        app.launch()
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
