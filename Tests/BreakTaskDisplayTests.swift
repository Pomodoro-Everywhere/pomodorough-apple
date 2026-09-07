import Foundation
import Testing
@testable import Pomodorough

@Suite("Break task display")
struct BreakTaskDisplayTests {
    @Test func breakPhasesAreMarkedBreak() {
        #expect(!TimerPhase.focus.isBreak)
        #expect(TimerPhase.shortBreak.isBreak)
        #expect(TimerPhase.longBreak.isBreak)
    }

    @Test func displayTaskKeepsFocusTask() throws {
        let task = try #require(FocusTask(title: "Write release notes"))
        let timer = TestFixtures.timer(
            status: .running, elapsed: 0, phase: .focus,
            taskID: task.id.uuidString.lowercased()
        )
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: timer, history: [], tasks: [task],
            state: PersistedTimerState.fresh()
        )
        #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot)?.id == task.id)
    }

    @Test func displayTaskHidesBreakTaskEvenWhenAttached() throws {
        let task = try #require(FocusTask(title: "Write release notes"))
        for phase in [TimerPhase.shortBreak, TimerPhase.longBreak] as [TimerPhase] {
            let timer = TestFixtures.timer(
                status: .running, elapsed: 0, phase: phase,
                taskID: task.id.uuidString.lowercased()
            )
            let snapshot = AppStatePublisher.Snapshot(
                canonicalTimer: timer, history: [], tasks: [task],
                state: PersistedTimerState.fresh()
            )
            #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot) == nil)
        }
    }

    @Test func displayTaskHidesUnassignedBreakWhileTasksExist() throws {
        let task = try #require(FocusTask(title: "Write release notes"))
        for phase in [TimerPhase.shortBreak, TimerPhase.longBreak] as [TimerPhase] {
            let timer = TestFixtures.timer(status: .running, elapsed: 0, phase: phase)
            let snapshot = AppStatePublisher.Snapshot(
                canonicalTimer: timer, history: [], tasks: [task],
                state: PersistedTimerState.fresh()
            )
            #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot) == nil)
        }
    }
}
