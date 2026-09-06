import UserNotifications

#if os(iOS)
import AlarmKit
#endif

enum AlarmAuthorizationProbe {
    case unavailable
    case notDetermined
    case authorized
    case denied

#if os(iOS)
    @available(iOS 26.0, *)
    static func current() -> AlarmAuthorizationProbe {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        @unknown default: return .denied
        }
    }
#endif
}

enum TimerAlertState {
    case on
    case off
    case notEnabled
    case limited
}

struct TimerAlertPresentation {
    let state: TimerAlertState
    let canEnable: Bool
    let needsSettings: Bool
}

func timerAlertPresentation(
    notification notificationStatus: UNAuthorizationStatus,
    alarm alarmState: AlarmAuthorizationProbe
) -> TimerAlertPresentation {
    switch (notificationStatus, alarmState) {
    case (.authorized, _), (.provisional, _), (.ephemeral, _), (_, .authorized):
        return TimerAlertPresentation(state: .on, canEnable: false, needsSettings: false)
    case (.denied, .denied), (.denied, .unavailable):
        return TimerAlertPresentation(state: .off, canEnable: false, needsSettings: true)
    case (.notDetermined, .notDetermined), (.notDetermined, .unavailable):
        return TimerAlertPresentation(state: .notEnabled, canEnable: true, needsSettings: false)
    default:
        return TimerAlertPresentation(
            state: .limited,
            canEnable: true,
            needsSettings: notificationStatus == .denied || alarmState == .denied
        )
    }
}
