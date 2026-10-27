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

// Privacy-safe widget failure counter (AP122): the widget extension cannot
// reach Sentry, so a decode failure only bumps this integer in the shared
// app group — never snapshot payload, task title, or error text. The main
// app drains it via takeDecodeFailures and reports the count. The stored
// value saturates at the ceiling so a never-opened app cannot grow state.
extension TimerWidgetSnapshot {
    static let decodeFailureCountKey = "widget-snapshot-decode-failures-v1"
    static let decodeFailureCountCeiling = 999

    static func recordDecodeFailure(in defaults: UserDefaults) {
        let count = defaults.integer(forKey: decodeFailureCountKey)
        defaults.set(min(count + 1, decodeFailureCountCeiling), forKey: decodeFailureCountKey)
    }

    /// Reads and clears the counter so each failure batch reports once.
    static func takeDecodeFailures(from defaults: UserDefaults) -> Int {
        let count = defaults.integer(forKey: decodeFailureCountKey)
        if count > 0 { defaults.removeObject(forKey: decodeFailureCountKey) }
        return count
    }
}

/// Carries only the drained failure count to Sentry — no snapshot content.
struct WidgetSnapshotDecodeError: Error {
    let count: Int
}
