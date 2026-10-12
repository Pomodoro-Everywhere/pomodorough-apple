import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP01 groups and reopen")
struct R48AP01GroupTests {
    @Test @MainActor
    func taskUpsertLostReopenQueued() throws {
        let controller = R48AP01DurableAdmissionTests().makeController()
        let task = try #require(FocusTask(title: "Reopen upsert"))
        var state = PersistedTimerState.fresh()
        state = try R48AP01DurableAdmissionTests().seedUpsert(state: state, controller: controller, task: task)
        let claimed = try R48AP01DurableAdmissionTests().claim(state: state)
        let reopened = try R48AP01DurableAdmissionTests().reopen(claimed.retired)
        #expect(reopened == claimed.retired)
        let second = try #require(FocusTask(title: "Second reopen"))
        let edited = try #require(try controller.plan(.task(.upsert, second), from: R48AP01DurableAdmissionTests().snapshot(reopened)))
        #expect(edited.state.pendingTaskOperations.count == 2)
        #expect(edited.state.pendingTaskOperations[0] == reopened.pendingTaskOperations[0])
    }

    @Test @MainActor
    func autoStartLostReopenQueued() throws {
        let controller = R48AP01DurableAdmissionTests().makeController()
        var state = PersistedTimerState.fresh()
        let first = try #require(try controller.plan(.setAutoStartBreaks(true), from: R48AP01DurableAdmissionTests().snapshot(state)))
        state = first.state
        let claimed = try R48AP01DurableAdmissionTests().claim(state: state)
        let reopened = try R48AP01DurableAdmissionTests().reopen(claimed.retired)
        let toggled = try #require(try controller.plan(.setAutoStartBreaks(false), from: R48AP01DurableAdmissionTests().snapshot(reopened)))
        #expect(toggled.state.pendingAutoStartOperations.count == 2)
    }

    @Test @MainActor
    func selectLostReopenQueued() throws {
        let controller = R48AP01DurableAdmissionTests().makeController()
        let task = try #require(FocusTask(title: "Reopen select"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]
        let first = try #require(try controller.plan(.selectTask(task.id), from: R48AP01DurableAdmissionTests().snapshot(state)))
        state = first.state
        let claimed = try R48AP01DurableAdmissionTests().claim(state: state)
        let reopened = try R48AP01DurableAdmissionTests().reopen(claimed.retired)
        let other = try #require(FocusTask(title: "Other reopen"))
        var withOther = reopened
        withOther.tasks.append(other)
        withOther.knownTasks.append(other)
        let edited = try #require(try controller.plan(.selectTask(other.id), from: R48AP01DurableAdmissionTests().snapshot(withOther)))
        #expect(edited.state.pendingSelectedTaskOperations.count == 2)
        #expect(edited.state.selectedTaskID == other.id)
    }

    @Test @MainActor
    func deleteDeselectGroupQueued() throws {
        let controller = R48AP01DurableAdmissionTests().makeController()
        let task = try #require(FocusTask(title: "Delete group"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]
        state.selectedTaskID = task.id
        let upsert = try #require(FocusTask(title: "Unrelated upsert"))
        state = try R48AP01DurableAdmissionTests().seedUpsert(state: state, controller: controller, task: upsert)
        let claimed = try R48AP01DurableAdmissionTests().claim(state: state)
        let before = claimed.retired
        let deleted = try #require(try controller.plan(.task(.delete, task), from: R48AP01DurableAdmissionTests().snapshot(before)))
        #expect(deleted.state.pendingTaskOperations.count == 2)
        #expect(deleted.state.pendingTaskOperations[0] == before.pendingTaskOperations[0])
        #expect(deleted.effects[0] == .persistAtomically(previous: before, rebuildsOnRollback: true))
    }

    @Test @MainActor
    func durationTerminalClearGroup() throws {
        let controller = R48AP01DurableAdmissionTests().makeController()
        var state = PersistedTimerState.fresh()
        state.canonicalTimer = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let planned = try #require(try controller.plan(.setDurationMinutes(35, for: .focus), from: R48AP01DurableAdmissionTests().snapshot(state)))
        #expect(planned.state.pendingDurationOperations.count == 1)
        #expect(planned.state.pendingCommands.count == 1)
        #expect(planned.state.pendingCommands[0].type == .clear)
    }
}
