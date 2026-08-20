import SwiftUI

struct SyncToolbarStatus: View {
    let model: AppModel

    var body: some View {
        Button {
            Task { await model.sync(force: true) }
        } label: {
            HStack(spacing: 6) {
                if model.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.conflictMessage == nil && !model.isHistoryResolutionBlocking ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.conflictMessage == nil && !model.isHistoryResolutionBlocking ? PomodoroughTheme.platform : PomodoroughTheme.signal)
                        .accessibilityHidden(true)
                }
                Text(model.syncLabel.uppercased())
                    .font(.caption2.monospaced().bold())
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Sync status, \(model.syncLabel)")
        .accessibilityHint(model.isSignedIn ? "Sync now" : "Sign in to sync across devices")
        .disabled(!model.isSignedIn || model.isSyncing || model.isHistoryResolutionBlocking)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    SyncToolbarStatus(model: AppModel.preview(.signedIn))
        .padding()
}
#endif
