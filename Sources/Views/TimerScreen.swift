import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @State private var showsAccount = false

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(
                size: geometry.size,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )

            ZStack {
                if layout == .landscape {
                    VStack(spacing: 10) {
                        if let conflict = model.conflictMessage {
                            ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                        }
                        TimerMachineCard(model: model, layout: layout)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .timerChromeHidden(true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            if let conflict = model.conflictMessage {
                                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                            }
                            TimerMachineCard(model: model, layout: layout)
                        }
                        .padding()
                        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 96 : 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .timerChromeHidden(false)
                }
            }
            .animation(.default, value: layout)
        }
        .background(TimerBackdrop())
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Timer" : "Pomodorough")
        .inlineNavigationTitleIfSupported()
        .refreshable { await model.sync(force: true) }
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SyncToolbarStatus(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
                    .accessibilityValue(model.syncLabel)
                    .accessibilityActions {
                        if model.isSignedIn && !model.isSyncing && !model.isHistoryResolutionBlocking {
                            Button("Sync now") {
                                Task { await model.sync(force: true) }
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showsAccount) { AccountView(model: model) }
#endif
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimerScreen(model: AppModel.preview(.running))
    }
}
#endif
