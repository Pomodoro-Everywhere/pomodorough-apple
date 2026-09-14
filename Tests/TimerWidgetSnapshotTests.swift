#if os(iOS)
import Foundation
import Testing
@testable import Pomodorough

struct TimerWidgetSnapshotTests {
    @Test func snapshotRoundTripsAndCompletesAtDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = TimerActivityAttributes.ContentState(
            phase: "focus", taskTitle: "Write", startedAt: start,
            endsAt: start.addingTimeInterval(60), remaining: 60, isPaused: false
        )
        let snapshot = TimerWidgetSnapshot(timer: timer)
        let decoded = try JSONDecoder().decode(TimerWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(!snapshot.isComplete(at: start.addingTimeInterval(59)))
        #expect(snapshot.isComplete(at: start.addingTimeInterval(60)))
        #expect(snapshot.isComplete(at: start.addingTimeInterval(600)))
    }

    @Test func pausedAndIdleSnapshotsDoNotCompleteWithWallClock() {
        let timer = TimerActivityAttributes.ContentState(
            phase: "short_break", taskTitle: nil, startedAt: .distantPast,
            endsAt: .distantPast, remaining: 42, isPaused: true
        )
        #expect(!TimerWidgetSnapshot(timer: timer).isComplete(at: .now))
        #expect(!TimerWidgetSnapshot(timer: nil).isComplete(at: .now))
    }
}
#endif
