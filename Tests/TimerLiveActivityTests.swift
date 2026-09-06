#if os(iOS)
import ActivityKit
import Foundation
import Testing
@testable import Pomodorough

@Suite("Live Activity timer deadlines")
struct TimerLiveActivityTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func runningDeadlineIncludesElapsedTimeBeforeAnchor() {
        let state = TimerActivityAttributes.ContentState(
            timer: timer(status: .running, elapsed: 600_000), taskTitle: "Write"
        )
        #expect(state.startedAt == anchor.addingTimeInterval(-600))
        #expect(state.endsAt == anchor.addingTimeInterval(900))
        #expect(state.endsAt.timeIntervalSince(state.startedAt) == 1500)
        #expect(state.remaining == 900)
        #expect(state.taskTitle == "Write")
        #expect(!state.isPaused)
    }

    @Test
    func pausedTimeDoesNotDependOnCurrentDate() throws {
        let state = TimerActivityAttributes.ContentState(
            timer: timer(status: .paused, elapsed: 600_000), taskTitle: nil
        )
        #expect(state.isPaused)
        #expect(state.remaining == 900)
        #expect(state.taskTitle == nil)
        // Both processes must round-trip the same wire representation.
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(TimerActivityAttributes.ContentState.self, from: data) == state)
    }

    @Test
    func resumedDeadlineMovesWithoutLosingProgress() {
        let resumed = CanonicalTimer(
            id: "timer-test", taskId: nil, phase: .longBreak, status: .running,
            plannedDurationMs: 1_500_000, elapsedAtAnchorMs: 600_000,
            anchorAt: anchor.addingTimeInterval(120), lastIntent: nil
        )
        let state = TimerActivityAttributes.ContentState(timer: resumed, taskTitle: nil)
        #expect(state.endsAt == anchor.addingTimeInterval(1020))
        #expect(state.remaining == 900)
        #expect(state.phase == "long_break")
    }

    @Test
    func completedDeadlineNeverGoesNegative() {
        let state = TimerActivityAttributes.ContentState(
            timer: timer(status: .completed, elapsed: 1_500_000), taskTitle: nil
        )
        #expect(state.remaining == 0)
        #expect(state.endsAt == anchor)
    }

    private func timer(status: CanonicalTimer.Status, elapsed: Int64) -> CanonicalTimer {
        CanonicalTimer(
            id: "timer-test", taskId: nil, phase: .focus, status: status,
            plannedDurationMs: 1_500_000, elapsedAtAnchorMs: elapsed,
            anchorAt: anchor, lastIntent: nil
        )
    }
}
#endif
