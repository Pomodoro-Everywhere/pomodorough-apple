#if os(macOS)
import AppKit
import Observation
#endif
import SwiftUI

#if os(macOS)
@MainActor
@Observable
final class MacOSDestinationState {
    var selectedTab = MainTab.timer
    var taskDraft = ""
    var networkRoomName = ""
    var isCreatingRoom = false
    var showsCompletedFocusBreakdown = false
}
#endif

struct MainContainer: View {
    let model: AppModel
#if os(iOS)
    @State private var selectedTab = MainTab.timer
#else
    @State private var destinationState = MacOSDestinationState()
    @State private var showsSettings = false
    @State private var showsAccount = false
#endif

    var body: some View {
        platformContent
            .disabled(model.isHistoryResolutionBlocking)
            .confirmationDialog(
                "Switch to \(model.pendingAccountSwitchUser?.email ?? "this account")?",
                isPresented: Binding(
                    get: { model.pendingAccountSwitchUser != nil },
                    set: { _ in }
                )
            ) {
                Button("Switch and remove local data", role: .destructive) {
                    Task { await model.confirmAccountSwitch() }
                }
                Button("Cancel account switch", role: .cancel) {
                    Task { await model.cancelAccountSwitch() }
                }
            } message: {
                Text("Switching removes this device's previous timer, tasks, history, settings, and queued changes. Cancel keeps the previous workspace on this device and signs out of the new account.")
            }
    }

    @ViewBuilder
    private var platformContent: some View {
#if os(iOS)
        if #available(iOS 18, *) {
            ModernTabs(model: model, selection: $selectedTab)
        } else {
            LegacyTabs(model: model, selection: $selectedTab)
        }
#else
        macOSContent
#endif
    }

#if os(macOS)
    private var macOSContent: some View {
        macOSDestination
            .animation(.default, value: destinationState.selectedTab)
            .inspector(isPresented: $showsSettings) {
                ServicePatternScreen(model: model, showsNavigationTitle: false)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
            .navigationTitle(macOSWindowTitle)
            .frame(minWidth: showsSettings ? 896 : 516)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    macOSNavigation
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    settingsButton
                    AccountSyncToolbarButton(model: model, showsAccount: $showsAccount)
                }
            }
            .sheet(isPresented: $showsAccount) { AccountView(model: model) }
    }

    @ViewBuilder
    private var macOSDestination: some View {
        switch destinationState.selectedTab {
        case .timer:
            NavigationStack { TimerScreen(model: model) }
        case .tasks:
            NavigationStack {
                TasksScreen(
                    model: model,
                    newTaskTitle: destinationBinding(\.taskDraft)
                )
            }
        case .history:
            NavigationStack {
                HistoryScreen(model: model) {
                    destinationState.showsCompletedFocusBreakdown = true
                }
                .navigationDestination(
                    isPresented: destinationBinding(\.showsCompletedFocusBreakdown)
                ) {
                    CompletedFocusBreakdownScreen(model: model)
                }
            }
        case .network:
            NavigationStack {
                NetworkScreen(
                    model: model,
                    roomName: destinationBinding(\.networkRoomName),
                    isCreatingRoom: destinationBinding(\.isCreatingRoom)
                )
            }
        case .pattern:
            NavigationStack { ServicePatternScreen(model: model) }
        }
    }

    private var macOSWindowTitle: String {
        switch destinationState.selectedTab {
        case .timer: String(localized: "Pomodorough")
        case .tasks: String(localized: "Tasks")
        case .history: String(localized: "Arrivals")
        case .network: String(localized: "Network")
        case .pattern: String(localized: "Pattern")
        }
    }

    private func destinationBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<MacOSDestinationState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { destinationState[keyPath: keyPath] },
            set: { destinationState[keyPath: keyPath] = $0 }
        )
    }

    private var macOSNavigation: some View {
        Picker("Section", selection: destinationBinding(\.selectedTab)) {
            Text("Timer").tag(MainTab.timer)
            Text("Tasks").tag(MainTab.tasks)
            Text("Arrivals").tag(MainTab.history)
            Text("Network").tag(MainTab.network)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Section")
        .help("Navigate between Timer, Tasks, Arrivals, and Network")
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "slider.horizontal.3") {
            toggleSettings()
        }
        .accessibilityValue("Pattern")
        .help("Settings, Pattern")
    }

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
