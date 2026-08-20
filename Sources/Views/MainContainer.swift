#if os(macOS)
import AppKit
#endif
import SwiftUI

struct MainContainer: View {
    let model: AppModel
    @State private var selectedTab = MainTab.timer
#if os(macOS)
    @State private var showsSettings = false
    @State private var showsAccount = false
#endif

    var body: some View {
        Group {
#if os(iOS)
        if #available(iOS 18, *) {
            ModernTabs(model: model, selection: $selectedTab)
        } else {
            LegacyTabs(model: model, selection: $selectedTab)
        }
#else
        TabView(selection: $selectedTab) {
            TimerScreen(model: model)
                .tabItem { Label("Timer", systemImage: "timer") }
                .tag(MainTab.timer)
            TasksScreen(model: model)
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(MainTab.tasks)
            NavigationStack {
                HistoryScreen(model: model)
            }
                .tabItem { Label("Arrivals", systemImage: "clock.arrow.circlepath") }
                .tag(MainTab.history)
        }
        .animation(.default, value: selectedTab)
        .inspector(isPresented: $showsSettings) {
            ServicePatternScreen(model: model)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .frame(minWidth: showsSettings ? 896 : 516)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Settings", systemImage: "slider.horizontal.3") {
                    toggleSettings()
                }
                AccountSyncToolbarButton(model: model, showsAccount: $showsAccount)
            }
        }
        .sheet(isPresented: $showsAccount) { AccountView(model: model) }
#endif
        }
        .disabled(model.isHistoryResolutionBlocking)
    }

#if os(macOS)
    private func toggleSettings() {
        let willShowSettings = !showsSettings
        guard willShowSettings,
              let window = NSApp.currentEvent?.window
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: \.isVisible),
              window.frame.width < 896 else {
            withAnimation(.default) {
                showsSettings = willShowSettings
            }
            return
        }

        var targetFrame = window.frame
        targetFrame.size.width = 896
        if let visibleFrame = window.screen?.visibleFrame,
           targetFrame.maxX > visibleFrame.maxX {
            targetFrame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - targetFrame.width)
        }

        let duration = window.animationResizeTime(targetFrame)
        withAnimation(.easeInOut(duration: duration)) {
            showsSettings = true
        }
        DispatchQueue.main.async {
            window.setFrame(targetFrame, display: true, animate: true)
        }
    }
#endif
}

#if DEBUG
#Preview {
    MainContainer(model: AppModel.preview(.populated))
}
#endif
