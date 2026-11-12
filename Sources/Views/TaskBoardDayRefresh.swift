import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Keeps the Tasks board's day current: at the next local midnight, and
/// when the calendar day, the time zone or the system clock changes.
struct TaskBoardDayRefresh: ViewModifier {
    @Binding var today: Date

    func body(content: Content) -> some View {
        content
            .task(id: today) {
                let midnight = TasksScreen.nextMidnight(after: today)
                let delay = midnight.timeIntervalSinceNow
                guard delay > 0 else {
                    today = Date.now
                    return
                }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                today = Date.now
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                today = Date.now
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                today = Date.now
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.clockChange)) { _ in
                today = Date.now
            }
    }

#if os(iOS)
    private static let clockChange = UIApplication.significantTimeChangeNotification
#else
    private static let clockChange = Notification.Name.NSSystemClockDidChange
#endif
}
