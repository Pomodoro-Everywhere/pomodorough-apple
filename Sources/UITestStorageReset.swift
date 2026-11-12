#if DEBUG
import Foundation
import OSLog

/// The DEBUG storage reset that iOS UI tests request with
/// `POMODOROUGH_UI_TEST_RESET=1` in the launch environment.
///
/// A UI-test app process is not a test process (it has no XCTest
/// configuration), so it runs on the default storage. In the iOS simulator
/// that is the simulator's app container. On macOS, which is not sandboxed,
/// and on a device it is the user's real profile and Keychain. The reset
/// therefore runs only in the simulator and refuses everywhere else.
///
/// On macOS every UI-test setting would reach the real profile, so a launch
/// with any of them stops before the app builds a store.
enum UITestStorageReset {
    static let environmentKey = "POMODOROUGH_UI_TEST_RESET"

    enum Decision: Equatable {
        case notRequested
        case reset
        case refused
    }

    /// Fixed at compile time, so no launch setting can turn it on.
    static var runsInSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    static func decision(environment: [String: String], runsInSimulator: Bool) -> Decision {
        guard environment[environmentKey] == "1" else { return .notRequested }
        return runsInSimulator ? .reset : .refused
    }

    /// Every UI-test launch setting starts with this prefix.
    static let uiTestEnvironmentPrefix = "POMODOROUGH_UI_TEST_"

    enum LaunchDecision: Equatable {
        case allowed
        case refused
    }

    /// Fixed at compile time, so no launch setting can turn it off.
    static var runsOnMac: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    /// A macOS UI-tested app would run every UI-test setting against the real
    /// profile, for example the room store reading `iroh-rooms-v1.json`.
    /// No macOS UI-test target exists, so any UI-test setting there is refused.
    static func launchDecision(environment: [String: String], runsOnMac: Bool) -> LaunchDecision {
        guard runsOnMac else { return .allowed }
        let requested = environment.keys.contains { $0.hasPrefix(uiTestEnvironmentPrefix) }
        return requested ? .refused : .allowed
    }

    @MainActor
    static func applyIfRequested(environment: [String: String]) {
        if launchDecision(environment: environment, runsOnMac: runsOnMac) == .refused {
            preconditionFailure("UI-test settings on macOS would use the real profile; no macOS UI-test target exists.")
        }
        switch decision(environment: environment, runsInSimulator: runsInSimulator) {
        case .notRequested:
            return
        case .refused:
            Logger(subsystem: "me.egigoka.pomodorough", category: "PomodoroughApp")
                .error("ui-test reset refused: it runs only in the iOS simulator")
        case .reset:
#if targetEnvironment(simulator)
            resetDefaultStorage()
#else
            preconditionFailure("ui-test reset outside the simulator; it would wipe the real profile.")
#endif
        }
    }

#if targetEnvironment(simulator)
    @MainActor
    private static func resetDefaultStorage() {
        DefaultStorageLocation.removeDefaults()
        do {
            try KeychainStore().delete()
        } catch {
            PomodoroughApp.uiTestResetFailed(error, step: "keychain-delete")
        }
        do {
            try IrohRoomStore.resetDefaultStorage()
        } catch {
            PomodoroughApp.uiTestResetFailed(error, step: "room-store-reset")
        }
        AppModel.resetDefaultDurableStorage()
    }
#endif
}
#endif
