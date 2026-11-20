import SwiftUI

struct SyncToolbarStatus: View {
    let model: AppModel

    var body: some View {
        // The status stays a Button when it cannot sync: the iOS 27 glass
        // bar sizes a plain view in the navigation slot to a circle and
        // cuts the label.
        Button {
            Task { await model.sync(force: true) }
        } label: {
            statusLabel
        }
        .accessibilityLabel(String(localized: "Sync status, \(model.syncLabel)"))
        .accessibilityHint(model.isSignedIn ? String(localized: "Sync now") : String(localized: "Sign in to sync across devices"))
        .disabled(!canSync)
    }

    private var canSync: Bool {
        model.isSignedIn && !model.isSyncing && !model.isHistoryResolutionBlocking
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isHealthy ? PomodoroughTheme.platform : PomodoroughTheme.signal)
                    .accessibilityHidden(true)
            }
            statusText
        }
    }

    /// IOS27-08: the system dims the label of a disabled bar button to
    /// about 2.3:1. The pinned secondary grey stays above 4.5:1.
    @ViewBuilder
    private var statusText: some View {
        let text = Text(model.syncLabel.localizedUppercase)
            .font(.caption2.monospaced().bold())
            .lineLimit(1)
        if canSync {
            text
        } else {
            text.foregroundStyle(PomodoroughTheme.secondaryText)
        }
    }

    private var isHealthy: Bool {
        model.conflictMessage == nil && !model.isHistoryResolutionBlocking
    }
}

#if DEBUG
#Preview {
    SyncToolbarStatus(model: AppModel.preview(.signedIn))
        .padding()
}
#endif
