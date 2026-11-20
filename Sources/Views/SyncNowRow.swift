import SwiftUI

/// Account's "Sync now" action. When the action cannot run, the button is
/// drawn grey and the reason sits under it, so a disabled button never
/// looks available (IOS27-11).
struct SyncNowRow: View {
    let availability: SyncNowAvailability
    let syncNow: () -> Void

    var body: some View {
        Button("Sync now", systemImage: "arrow.triangle.2.circlepath", action: syncNow)
            .foregroundStyle(buttonStyle)
            .disabled(!availability.isAvailable)
        if let reason = availability.unavailableReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(PomodoroughTheme.secondaryText)
        }
    }

    private var buttonStyle: AnyShapeStyle {
        availability.isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(PomodoroughTheme.secondaryText)
    }
}
