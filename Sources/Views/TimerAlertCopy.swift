#if os(iOS) || os(macOS)
import Foundation

/// Timer alert copy for the alert paths this device offers. iOS 26 and
/// later add a system timer alarm; iOS 18 through 25 deliver notifications
/// only, so their copy must not promise an alarm or call the device "older"
/// (IOS18-04). macOS keeps its own notification description.
enum TimerAlertCopy {
    case alarmAndNotification
    case notificationOnly
    case desktopNotification

    static var current: TimerAlertCopy {
#if os(iOS)
        if #available(iOS 26.0, *) { return .alarmAndNotification }
        return .notificationOnly
#else
        return .desktopNotification
#endif
    }

    /// Introduction summary of what Pomodorough asks the system for.
    var introductionSummary: String {
        switch self {
        case .alarmAndNotification, .desktopNotification:
            String(localized: "Pomodorough requests an operating-system notification or alarm when a focus run or break ends. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
        case .notificationOnly:
            String(localized: "Pomodorough requests an operating-system notification when a focus run or break ends. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
        }
    }

    /// Account summary of the completion alert guarantee.
    var accountSummary: String {
        switch self {
        case .alarmAndNotification, .desktopNotification:
            String(localized: "Pomodorough requests an operating-system notification or alarm for timer completion. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
        case .notificationOnly:
            String(localized: "Pomodorough requests an operating-system notification for timer completion. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
        }
    }

    /// Detail on the Notifications permission card.
    var notificationDetail: String {
        switch self {
        case .alarmAndNotification:
            String(localized: "Sends a backup alert when an interval ends. Used on older iOS versions or when alarms are unavailable.")
        case .notificationOnly:
            String(localized: "Sends an alert when a focus run or break ends, including while Pomodorough is not open. Delivery is controlled by iOS.")
        case .desktopNotification:
            String(localized: "Sends an alert and plays a sound until you dismiss it or start another timer.")
        }
    }
}
#endif
