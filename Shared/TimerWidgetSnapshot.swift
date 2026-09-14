import Foundation

struct TimerWidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.me.egigoka.pomodorough"
    static let storageKey = "timer-widget-snapshot-v1"
    static let kind = "PomodoroughTimer"

    let timer: TimerActivityAttributes.ContentState?

    func isComplete(at date: Date) -> Bool {
        guard let timer else { return false }
        return !timer.isPaused && timer.endsAt <= date
    }
}
