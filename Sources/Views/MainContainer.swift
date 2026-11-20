import SwiftUI

struct MainContainer: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(iOS)
    @State private var selectedTab = MainTab.timer
#else
    @State private var destinationState = MacOSDestinationState()
    @State private var showsAccount = false
#endif

    var body: some View {
        platformContent
#if os(iOS)
            .onOpenURL { url in
                if Self.handleTimerURL(url, model: model) {
                    selectedTab = .timer
                }
            }
#endif
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

    @discardableResult
    static func handleTimerURL(_ url: URL, model: AppModel) -> Bool {
        guard url.scheme == "pomodorough", url.host == "timer" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "toggle" }) {
            model.toggleTimer()
        } else if let action = items.first(where: { $0.name == "action" })?.value {
            switch action {
            case "finish": model.finish()
            case "cancel": model.cancel()
            case "skip": model.selectPhase(model.skipDestination)
            default: break
            }
        }
        return true
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
            .animation(reduceMotion ? nil : .default, value: destinationState.selectedTab)
            .navigationTitle(MacOSSectionTitle.title(for: destinationState.selectedTab))
            .focusedSceneValue(\.macOSDestination, destinationState)
            // A section command may have opened this window with nothing focused.
            .adoptsRequestedSection(into: destinationState)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    macOSNavigation
                }
                ToolbarItem(placement: .primaryAction) {
                    AccountSyncToolbarButton(model: model, showsAccount: $showsAccount)
                }
            }
            .sheet(isPresented: $showsAccount) { AccountView(model: model) }
            .onChange(of: showsAccount) { _, isShown in
                // Account covers the Tasks screen, so the undo window ends.
                if isShown { model.pendingTaskDeletion.flush() }
            }
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

    private func destinationBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<MacOSDestinationState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { destinationState[keyPath: keyPath] },
            set: { destinationState[keyPath: keyPath] = $0 }
        )
    }

    /// MAC-02: Pattern is a section like the others, in the order of
    /// MacOSSectionCommands.sections, so it opens in the window instead of
    /// an inspector that widened the window.
    private var macOSNavigation: some View {
        Picker("Section", selection: destinationBinding(\.selectedTab)) {
            Text("Timer").tag(MainTab.timer)
            Text("Tasks").tag(MainTab.tasks)
            Text("Pattern").tag(MainTab.pattern)
            Text("Arrivals").tag(MainTab.history)
            Text("Network").tag(MainTab.network)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Section")
        .help("Navigate between Timer, Tasks, Pattern, Arrivals, and Network")
    }
#endif
}

#if DEBUG
#Preview {
    MainContainer(model: AppModel.preview(.populated))
        .environment(PendingTaskDeletion())
}
#endif
