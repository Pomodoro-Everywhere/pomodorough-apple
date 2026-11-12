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
        // No minimum height: small phones in landscape (e.g. SE, 375pt)
        // must fit the tab/navigation hierarchy in actual available space.
        .frame(minWidth: 320)
#endif
        // IOS27-07: tab labels, toolbar glyphs, text buttons and focus rings
        // take the darkened signal in the light appearance.
        .tint(PomodoroughTheme.signalText)
        .environment(model.pendingTaskDeletion)
#if os(iOS) || os(watchOS)
        // One success tap per phase completion, whichever tab is showing.
        .sensoryFeedback(.success, trigger: model.completionAlertTimerID) { _, alerting in
            alerting != nil
        }
#endif
        .modifier(ErrorMessageAlert(model: model, host: .root))
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

#if DEBUG
#Preview {
    RootView(model: AppModel.preview(.populated))
}
#endif
