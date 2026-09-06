import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.snapshotLoadFailure != nil {
                snapshotRecovery
            } else {
                switch model.sessionState {
                case .restoring:
                    LaunchView()
                case .localOnly:
                    destination
                case .signedIn:
                    destination
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 516, minHeight: 420)
#else
        .frame(minWidth: 320, minHeight: 420)
#endif
        .tint(PomodoroughTheme.signal)
#if os(iOS)
        .overlay(alignment: .top) {
            WatchDiagLine(sync: model.watchSync)
                .padding(.top, 4)
        }
#endif
        .alert("Pomodorough", isPresented: errorPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: historyResolutionPresented) {
            HistoryResolutionView(model: model)
                .interactiveDismissDisabled()
        }
    }

    private var snapshotRecovery: some View {
        ContentUnavailableView {
            Label("Workspace unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(model.snapshotLoadFailure?.localizedDescription ?? "")
        } actions: {
            Button("Retry loading workspace") {
                Task { await model.retrySnapshotLoad() }
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var historyResolutionPresented: Binding<Bool> {
        Binding(
            get: { model.isHistoryResolutionBlocking },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var destination: some View {
#if os(iOS) || os(macOS)
        if model.needsPermissionIntroduction {
            PermissionIntroductionView(model: model)
        } else {
            MainContainer(model: model)
        }
#else
        MainContainer(model: model)
#endif
    }
}

#if os(iOS)
// TEMP debug: iOS-side WatchConnectivity state, remove once watch sync is live.
private struct WatchDiagLine: View {
    @ObservedObject var sync: WatchSyncService

    var body: some View {
        Text(sync.diagLine)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(4)
    }
}
#endif

#if DEBUG
#Preview {
    RootView(model: AppModel.preview(.populated))
}
#endif
