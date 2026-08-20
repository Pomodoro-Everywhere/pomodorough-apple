#if os(macOS)
import SwiftUI

struct AccountSyncToolbarButton: View {
    let model: AppModel
    @Binding var showsAccount: Bool

    var body: some View {
        Button {
            showsAccount = true
        } label: {
            if !model.isSignedIn {
                Text("Sign in")
            } else if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
            }
        }
        .help(model.isSignedIn ? model.syncLabel : "Sign in")
        .accessibilityLabel(model.isSignedIn ? "Account, \(model.syncLabel)" : "Sign in")
    }

    private var statusSymbol: String {
        if model.conflictMessage != nil || model.isHistoryResolutionBlocking {
            return "exclamationmark.triangle.fill"
        }
        if model.isOffline {
            return "wifi.slash"
        }
        if model.pendingChangeCount > 0 {
            return "clock.arrow.circlepath"
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if model.conflictMessage != nil || model.isHistoryResolutionBlocking
            || model.isOffline || model.pendingChangeCount > 0 {
            return PomodoroughTheme.signal
        }
        return PomodoroughTheme.platform
    }
}

#if DEBUG
#Preview {
    AccountSyncToolbarButton(
        model: AppModel.preview(.signedIn),
        showsAccount: .constant(false)
    )
    .padding()
}
#endif
#endif
