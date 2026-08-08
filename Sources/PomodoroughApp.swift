import SwiftUI

@main
struct PomodoroughApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_RESET"] == "1" {
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            }
            try? KeychainStore().delete()
            try? IrohRoomStore.resetDefaultStorage()
        }
#endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
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
        .windowResizability(.contentMinSize)
#endif
    }

    @MainActor
    @discardableResult
    static func handleGoogleSignInURL(_ url: URL, model: AppModel) -> Bool {
        model.handleGoogleSignInURL(url)
    }
}
