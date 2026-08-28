#if os(iOS) || os(macOS)
import SwiftUI

struct PermissionIntroductionView: View {
    let model: AppModel
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            RailwayBackdrop()
            ScrollView {
                VStack(spacing: 24) {
                    introduction
                    permissionCards
                    actions
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            RouteClockMark()
            Text("BEFORE DEPARTURE")
                .font(.caption.monospaced().bold())
                .tracking(2)
                .foregroundStyle(PomodoroughTheme.ticket)
            Text("Hear when time is up")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.porcelain)
            Text("Pomodorough requests an operating-system notification or alarm when a focus run or break ends. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.sky)
        }
        .accessibilityRepresentation {
            Text("Hear when time is up")
                .accessibilityValue("Pomodorough requests an operating-system notification or alarm when a focus run or break ends. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
        }
    }

    @ViewBuilder
    private var permissionCards: some View {
        VStack(spacing: 12) {
            PermissionIntroductionCard(
                icon: "bell.badge.fill",
                title: "Notifications",
                detail: notificationDetail,
                color: PomodoroughTheme.sky
            )
#if os(iOS)
            if #available(iOS 26.0, *) {
                PermissionIntroductionCard(
                    icon: "alarm.fill",
                    title: "Alarms",
                    detail: "Requests a system timer alarm at the end, including while Pomodorough is not open. Delivery is controlled by iOS.",
                    color: PomodoroughTheme.signal
                )
            }
#endif
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isRequesting = true
                Task {
                    await model.allowTimerAlerts()
                    isRequesting = false
                }
            } label: {
                HStack(spacing: 10) {
                    if isRequesting { ProgressView().tint(PomodoroughTheme.platform) }
                    Text("Allow timer alerts").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PomodoroughTheme.platform)
            .background(PomodoroughTheme.ticket, in: .rect(cornerRadius: 14))
            .disabled(isRequesting)
            Button("Not now", action: model.skipTimerAlertPermissions)
                .font(.headline)
                .foregroundStyle(PomodoroughTheme.porcelain)
                .frame(minHeight: 44)
                .disabled(isRequesting)
                .accessibilityHint("Continues without timer alerts. The timer still works while Pomodorough is open.")
            Text("Permissions are optional. The timer still works while Pomodorough is open.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.steel)
                .accessibilityHidden(true)
        }
    }

    private var notificationDetail: String {
#if os(iOS)
        String(localized: "Sends a backup alert when an interval ends. Used on older iOS versions or when alarms are unavailable.")
#else
        String(localized: "Sends an alert and plays a sound until you dismiss it or start another timer.")
#endif
    }
}

#if DEBUG
#Preview {
    PermissionIntroductionView(model: AppModel.preview(.local))
}
#endif
#endif
