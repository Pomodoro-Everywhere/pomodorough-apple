import Foundation
import Testing
@testable import Pomodorough

// B8: client-side input rules that mirror what Core accepts, and the
// planned wording of history rows whose run did not take its time.
struct InputRulesTests {
    @Test(arguments: ["", " ", "   ", "\n", "\t \n"])
    func blankDraftsAreRefused(draft: String) {
        #expect(FocusTask.isBlankDraft(draft))
        #expect(!FocusTask.acceptsDraft(draft))
    }

    @Test(arguments: ["a", " a ", "Write notes", "  two  spaces  "])
    func draftsWithTextAreAccepted(draft: String) {
        #expect(!FocusTask.isBlankDraft(draft))
        #expect(FocusTask.acceptsDraft(draft))
    }

    @Test func stepperBoundsMatchTheWireRange() {
        #expect(DurationValues.minuteRange == 1...180)
        #expect(!DurationValues.canReduce(minutes: 1))
        #expect(DurationValues.canReduce(minutes: 2))
        #expect(DurationValues.canIncrease(minutes: 179))
        #expect(!DurationValues.canIncrease(minutes: 180))
    }

    @Test(arguments: [("cancelled", true), ("superseded", true), ("completed", false)])
    func plannedWordingFollowsTheStatus(status: String, planned: Bool) {
        let item = HistoryItem(
            id: "history-\(status)", timerId: "timer-\(status)", commandId: nil, taskId: nil,
            phase: .focus, status: status, plannedDurationMs: 25 * 60_000,
            completedAt: nil, endedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(item.isPlannedDurationOnly == planned)
        #expect(item.durationText == (planned ? "25 min planned" : TaskTimeText.shortMinutes(25)))
        #expect(item.spokenDurationText == (planned ? "25 minutes planned" : "25 minutes"))
    }
}
