import SwiftUI
import OSLog

@main
struct PomodoroughApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
#if os(macOS)
    @StateObject private var menuBarClock = MenuBarTimerClock()
    @AppStorage(MenuBarTimerDisplay.defaultsKey) private var menuBarDisplay = MenuBarTimerDisplay.current
#endif

    init() {
        SentrySetup.startIfConfigured()
#if DEBUG
        if ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_RESET"] == "1" {
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            }
            do {
                try KeychainStore().delete()
            } catch {
                Self.uiTestResetFailed(error, step: "keychain-delete")
            }
            do {
                try IrohRoomStore.resetDefaultStorage()
            } catch {
                Self.uiTestResetFailed(error, step: "room-store-reset")
            }
            AppModel.resetDefaultDurableStorage()
        }
#endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(model: model)
#if os(iOS)
                .modifier(TimerLiveActivityModifier(model: model))
#endif
                .task {
                    model.setSceneActive(scenePhase == .active)
                    await model.restore()
                }
                .onOpenURL { Self.handleGoogleSignInURL($0, model: model) }
                .onChange(of: scenePhase) { _, phase in
                    let isActive = phase == .active
                    model.setSceneActive(isActive)
                    if isActive {
                        Task { await model.refreshAfterForeground() }
                    }
                }
        }
#if os(macOS)
        .defaultSize(width: 920, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
#endif
#if os(macOS)
        MenuBarExtra {
            MenuBarTimerMenu(model: model)
        } label: {
            MenuBarTimerLabel(model: model, date: menuBarClock.date, display: menuBarDisplay)
        }
        .menuBarExtraStyle(.menu)
#endif
    }

    @MainActor
    @discardableResult
    static func handleGoogleSignInURL(_ url: URL, model: AppModel) -> Bool {
        model.handleGoogleSignInURL(url)
    }

    // Test seam: DEBUG UI-test reset keeps its outcome (reset continues) and
    // captures Error-only (Keychain/file error, never tokens or room data).
    static func uiTestResetFailed(_ error: Error, step: String) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "PomodoroughApp")
            .error("ui-test reset \(step, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        SentryCapture.capture(error)
    }
}
