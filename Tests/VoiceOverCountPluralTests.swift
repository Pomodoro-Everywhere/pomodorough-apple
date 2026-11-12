import Foundation
import Testing
@testable import Pomodorough

// Pins VoiceOver count grammar: every count in a composed accessibility
// string pluralizes on its own ("1 run", "3 runs"; "1 finished pomodoro").
@MainActor
@Suite("VoiceOver count plurals")
struct VoiceOverCountPluralTests {
    @Test func breakdownValuePluralizesRuns() {
        #expect(HistoryScreen.breakdownAccessibilityValue(completed: 1, runs: 1) == "1 completed of 1 run")
        #expect(HistoryScreen.breakdownAccessibilityValue(completed: 2, runs: 3) == "2 completed of 3 runs")
        #expect(HistoryScreen.breakdownAccessibilityValue(completed: 0, runs: 0) == "0 completed of 0 runs")
    }

    @Test func taskRowLabelPluralizesFinishedPomodoros() throws {
        let task = try #require(FocusTask(title: "Deep work"))
        let one = TaskDailySummary(task: task, finishedPomodoros: 1, timeSpentMs: 60_000)
        #expect(TaskSummaryRow.accessibilityLabel(for: one) == "1 finished pomodoro, 1 minute spent")
        let many = TaskDailySummary(task: task, finishedPomodoros: 4, timeSpentMs: 100 * 60_000)
        #expect(
            TaskSummaryRow.accessibilityLabel(for: many)
                == "4 finished pomodoros, \(TaskTimeText.spoken(many.timeSpentMs)) spent"
        )
    }

    @Test func taskBoardHeroValuePluralizesFinishedPomodoros() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let one = TaskBoardHero.accessibilityValue(finishedPomodoros: 1, timeSpentMs: 25 * 60_000, date: date)
        #expect(one == "\(day), 1 finished pomodoro, 25 minutes focus time")
        let three = TaskBoardHero.accessibilityValue(finishedPomodoros: 3, timeSpentMs: 75 * 60_000, date: date)
        #expect(three == "\(day), 3 finished pomodoros, \(TaskTimeText.spoken(75 * 60_000)) focus time")
    }
}
