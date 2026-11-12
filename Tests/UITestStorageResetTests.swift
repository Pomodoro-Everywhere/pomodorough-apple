import Testing
@testable import Pomodorough

/// The UI-test reset wipes the default storage. Outside the simulator that is
/// the user's real profile, so it must refuse there. These tests check the
/// decision only; they never call the reset.
struct UITestStorageResetTests {
    private static let requested = [UITestStorageReset.environmentKey: "1"]

    @Test func resetRunsOnlyInTheSimulator() {
        #expect(UITestStorageReset.decision(environment: Self.requested, runsInSimulator: true) == .reset)
        #expect(UITestStorageReset.decision(environment: Self.requested, runsInSimulator: false) == .refused)
    }

    @Test(arguments: [[:], [UITestStorageReset.environmentKey: "0"], [UITestStorageReset.environmentKey: "true"]])
    func resetNeedsTheExactRequest(environment: [String: String]) {
        for runsInSimulator in [true, false] {
            #expect(UITestStorageReset.decision(environment: environment, runsInSimulator: runsInSimulator) == .notRequested)
        }
    }

    /// The decision this build makes for a requested reset.
    @Test func thisBuildDecidesByItsDestination() {
        let decision = UITestStorageReset.decision(
            environment: Self.requested,
            runsInSimulator: UITestStorageReset.runsInSimulator
        )
#if os(macOS)
        #expect(!UITestStorageReset.runsInSimulator)
        #expect(decision == .refused, "a macOS process must never wipe the real profile")
#elseif targetEnvironment(simulator)
        #expect(UITestStorageReset.runsInSimulator)
        #expect(decision == .reset)
#else
        #expect(decision == .refused, "a device must never wipe the real profile")
#endif
    }

    /// Every UI-test setting the app reads, plus one the app does not know yet.
    private static let uiTestSettings = [
        "POMODOROUGH_UI_TEST_RESET", "POMODOROUGH_UI_TEST_ROOM_SECRETS", "POMODOROUGH_UI_TEST_DIAL",
        "POMODOROUGH_UI_TEST_LAYOUT", "POMODOROUGH_UI_TEST_HINGE", "POMODOROUGH_UI_TEST_HELD_INPUT",
        "POMODOROUGH_UI_TEST_INVITE", "POMODOROUGH_UI_TEST_FUTURE",
    ]

    @Test(arguments: uiTestSettings)
    func macLaunchRefusesAnyUITestSetting(key: String) {
        for value in ["1", "0", "", "unavailable"] {
            #expect(UITestStorageReset.launchDecision(environment: [key: value], runsOnMac: true) == .refused)
            #expect(UITestStorageReset.launchDecision(environment: [key: value], runsOnMac: false) == .allowed)
        }
    }

    @Test(arguments: [[:], ["POMODOROUGH_SILENCE_AUDIO": "1"], ["POMODOROUGH_UI_TEST": "1"], ["XPOMODOROUGH_UI_TEST_RESET": "1"]])
    func macLaunchAllowsOtherSettings(environment: [String: String]) {
        #expect(UITestStorageReset.launchDecision(environment: environment, runsOnMac: true) == .allowed)
    }

    /// The launch decision this build makes for a UI-test setting.
    @Test func thisBuildRefusesUITestSettingsOnlyOnMac() {
        let decision = UITestStorageReset.launchDecision(
            environment: Self.requested,
            runsOnMac: UITestStorageReset.runsOnMac
        )
#if os(macOS)
        #expect(UITestStorageReset.runsOnMac)
        #expect(decision == .refused, "a macOS UI-tested app would use the real profile")
#else
        #expect(!UITestStorageReset.runsOnMac)
        #expect(decision == .allowed)
#endif
    }
}
