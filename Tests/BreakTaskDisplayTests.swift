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

    @Test func localRetargetOverridesCanonicalTaskForActiveFocusTimer() throws {
        let oldTask = try #require(FocusTask(title: "Old task"))
        let newTask = try #require(FocusTask(title: "New task"))
        let timer = TestFixtures.timer(
            status: .running, elapsed: 0, phase: .focus,
            taskID: oldTask.id.uuidString.lowercased()
        )
        var state = PersistedTimerState.fresh()
        state.legacyTaskAssignments[timer.id] = newTask.id
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: timer, history: [], tasks: [oldTask, newTask],
            state: state
        )
        #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot)?.id == newTask.id)
    }

    @Test func selectedTaskSyncWithoutRetargetKeepsActiveTimerTask() throws {
        let activeTask = try #require(FocusTask(title: "Active task"))
        let nextTask = try #require(FocusTask(title: "Next task"))
        let timer = TestFixtures.timer(
            status: .running, elapsed: 0, phase: .focus,
            taskID: activeTask.id.uuidString.lowercased()
        )
        var state = PersistedTimerState.fresh()
        state.selectedTaskID = nextTask.id
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: timer, history: [], tasks: [activeTask, nextTask],
            state: state
        )
        #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot)?.id == activeTask.id)
    }

    // AP91: post-ack completion keeps following the local retarget
    // marker across display, per-task summaries, focus summaries,
    // and history context, while the stored history row keeps the
    // core-authoritative (old) taskId for other devices.
    @Test func retargetedCompletionFollowsMarkerInDisplayAndHistory() throws {
        let oldTask = try #require(FocusTask(title: "Old task"))
        let newTask = try #require(FocusTask(title: "New task"))
        let completedAt = Date(timeIntervalSince1970: 1_774_166_400)
        let timerID = "timer-retarget-complete"
        let item = TestFixtures.history(
            id: timerID,
            durationMs: 60_000,
            date: completedAt,
            taskID: oldTask.id.uuidString.lowercased()
        )
        let terminal = TestFixtures.timer(
            status: .completed, elapsed: 60_000, phase: .focus,
            timerID: timerID, taskID: oldTask.id.uuidString.lowercased()
        )
        var state = PersistedTimerState.fresh()
        state.legacyTaskAssignments[timerID] = newTask.id
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: terminal, history: [item],
            tasks: [oldTask, newTask], state: state
        )
        let publisher = AppStatePublisher()
        #expect(item.taskId == oldTask.id.uuidString.lowercased())
        #expect(publisher.task(forTimerID: timerID, snapshot: snapshot)?.id == newTask.id)
        #expect(publisher.displayTask(for: terminal, snapshot: snapshot)?.id == newTask.id)
        #expect(publisher.taskContext(for: item, snapshot: snapshot) == newTask.title)
        let summaries = publisher.taskSummaries(
            for: completedAt, calendar: .current, snapshot: snapshot
        )
        #expect(summaries.first(where: { $0.task.id == newTask.id })?.finishedPomodoros == 1)
        #expect(summaries.first(where: { $0.task.id == oldTask.id })?.finishedPomodoros == 0)
        #expect(publisher.completedFocusSummaries(snapshot: snapshot).first?.taskTitle == newTask.title)
        let hero = publisher.dayFocusTotals(for: completedAt, calendar: .current, snapshot: snapshot)
        #expect(hero.finishedPomodoros == 1)
        #expect(hero.timeSpentMs == 60_000)
    }

    @Test func retargetMarkerForUnknownTaskFallsBackToCanonical() throws {
        let oldTask = try #require(FocusTask(title: "Old task"))
        let timer = TestFixtures.timer(
            status: .running, elapsed: 0, phase: .focus,
            taskID: oldTask.id.uuidString.lowercased()
        )
        var state = PersistedTimerState.fresh()
        state.legacyTaskAssignments[timer.id] = UUID()
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: timer, history: [], tasks: [oldTask],
            state: state
        )
        #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot)?.id == oldTask.id)
    }

    @Test func breakTimerWithRetargetMarkerStaysHidden() throws {
        let oldTask = try #require(FocusTask(title: "Old task"))
        let newTask = try #require(FocusTask(title: "New task"))
        let timer = TestFixtures.timer(
            status: .running, elapsed: 0, phase: .shortBreak,
            taskID: oldTask.id.uuidString.lowercased()
        )
        var state = PersistedTimerState.fresh()
        state.legacyTaskAssignments[timer.id] = newTask.id
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: timer, history: [], tasks: [oldTask, newTask],
            state: state
        )
        #expect(AppStatePublisher().displayTask(for: timer, snapshot: snapshot) == nil)
    }

    @Test func completionWithoutRetargetKeepsCanonicalTask() throws {
        let task = try #require(FocusTask(title: "Kept task"))
        let completedAt = Date(timeIntervalSince1970: 1_774_166_400)
        let timerID = "timer-no-retarget-complete"
        let item = TestFixtures.history(
            id: timerID,
            durationMs: 60_000,
            date: completedAt,
            taskID: task.id.uuidString.lowercased()
        )
        let terminal = TestFixtures.timer(
            status: .completed, elapsed: 60_000, phase: .focus,
            timerID: timerID, taskID: task.id.uuidString.lowercased()
        )
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: terminal, history: [item],
            tasks: [task], state: PersistedTimerState.fresh()
        )
        let publisher = AppStatePublisher()
        #expect(publisher.task(forTimerID: timerID, snapshot: snapshot)?.id == task.id)
        #expect(publisher.taskContext(for: item, snapshot: snapshot) == task.title)
    }
}
