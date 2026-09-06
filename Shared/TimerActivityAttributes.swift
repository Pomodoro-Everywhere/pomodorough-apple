import ActivityKit
import Foundation

struct TimerActivityAttributes: ActivityAttributes {
    let timerID: String

    struct ContentState: Codable, Hashable {
        let phase: String
        let taskTitle: String?
        let startedAt: Date
        let endsAt: Date
        let remaining: TimeInterval
        let isPaused: Bool
    }
}

#if os(iOS)
import AlarmKit

@available(iOS 26.0, *)
struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let phase: String
}
#endif
