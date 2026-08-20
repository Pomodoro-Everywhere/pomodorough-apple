#if os(iOS) || os(macOS)
import SwiftUI

struct PermissionIntroductionCard: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(PomodoroughTheme.platform)
                .frame(width: 46, height: 46)
                .background(color, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(PomodoroughTheme.porcelain)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(PomodoroughTheme.sky)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(PomodoroughTheme.platform.opacity(0.9), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.porcelain.opacity(0.12), lineWidth: 1)
        }
        .accessibilityRepresentation {
            Text(title)
                .accessibilityValue(detail)
        }
    }
}

#if DEBUG
#Preview {
    PermissionIntroductionCard(
        icon: "bell.badge.fill",
        title: "Notifications",
        detail: "Sends an alert when an interval ends.",
        color: PomodoroughTheme.sky
    )
    .padding()
    .background(PomodoroughTheme.platform)
}
#endif
#endif
