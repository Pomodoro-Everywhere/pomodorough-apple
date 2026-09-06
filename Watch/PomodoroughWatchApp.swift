import SwiftUI

@main
struct PomodoroughWatchApp: App {
    @StateObject private var sync = WatchSyncService()

    var body: some Scene {
        WindowGroup {
            WatchTimerView()
                .environmentObject(sync)
        }
    }
}
