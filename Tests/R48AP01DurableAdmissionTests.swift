import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP01 durable queued admission")
struct R48AP01DurableAdmissionTests {
    @Test @MainActor
    func durationInFlightQueuedPreservesOldProof() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state: state, controller: controller, minutes: 30)
        let claimed = try claim(state: state)
        let before = claimed.retired
        let edited = try #require(try controller.plan(
            .setDurationMinutes(35, for: .focus),
            from: snapshot(before)
        ))
        #expect(edited.state.pendingDurationOperations.count == 2)
        #expect(edited.state.pendingDurationOperations[0] == before.pendingDurationOperations[0])
        #expect(edited.state.neverSentDurationOperationIDs.contains(edited.state.pendingDurationOperations[1].id))
        #expect(!edited.state.neverSentDurationOperationIDs.contains(before.pendingDurationOperations[0].id))
        #expect(edited.effects[0] == .persistAtomically(previous: before, rebuildsOnRollback: true))
        #expect(edited.effects[1] == .launchSync)
        #expect(edited.state.settings.focusMinutes == 35)
    }

    @Test @MainActor
    func durationLostReopenQueued() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state: state, controller: controller, minutes: 30)
        let claimed = try claim(state: state)
        let reopened = try reopen(claimed.retired)
        #expect(reopened == claimed.retired)
        let edited = try #require(try controller.plan(
            .setDurationMinutes(35, for: .focus),
            from: snapshot(reopened)
        ))
        #expect(edited.state.pendingDurationOperations.count == 2)
        #expect(edited.state.pendingDurationOperations[0].id == reopened.pendingDurationOperations[0].id)
    }

    @Test @MainActor
    func taskUpsertInFlightQueued() throws {
        let controller = makeController()
        let task = try #require(FocusTask(title: "Queued upsert"))
        var state = PersistedTimerState.fresh()
        state = try seedUpsert(state: state, controller: controller, task: task)
        let claimed = try claim(state: state)
        let before = claimed.retired
        let second = try #require(FocusTask(title: "Second upsert"))
        let edited = try #require(try controller.plan(.task(.upsert, second), from: snapshot(before)))
        #expect(edited.state.pendingTaskOperations.count == 2)
        #expect(edited.state.pendingTaskOperations[0] == before.pendingTaskOperations[0])
        #expect(edited.effects[0] == .persistAtomically(previous: before, rebuildsOnRollback: true))
    }

    @Test @MainActor
    func autoStartInFlightQueued() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        let first = try #require(try controller.plan(.setAutoStartBreaks(true), from: snapshot(state)))
        state = first.state
        let claimed = try claim(state: state)
        let before = claimed.retired
        let toggled = try #require(try controller.plan(.setAutoStartBreaks(false), from: snapshot(before)))
        #expect(toggled.state.pendingAutoStartOperations.count == 2)
        #expect(toggled.state.pendingAutoStartOperations[0].id == before.pendingAutoStartOperations[0].id)
    }

    @Test @MainActor
    func selectTaskInFlightQueued() throws {
        let controller = makeController()
        let task = try #require(FocusTask(title: "Select queued"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]
        let first = try #require(try controller.plan(.selectTask(task.id), from: snapshot(state)))
        state = first.state
        let claimed = try claim(state: state)
        let before = claimed.retired
        let other = try #require(FocusTask(title: "Other task"))
        var withOther = before
        withOther.tasks.append(other)
        withOther.knownTasks.append(other)
        let edited = try #require(try controller.plan(.selectTask(other.id), from: snapshot(withOther)))
        #expect(edited.state.pendingSelectedTaskOperations.count == 2)
        #expect(edited.state.selectedTaskID == other.id)
    }

    @Test @MainActor
    func pauseBehindSentStartIsStaleIneligible() throws {
        let controller = makeController(timerID: "timer-R48AP01-pause")
        var state = PersistedTimerState.fresh()
        let started = try #require(try controller.plan(.startTimer, from: snapshot(state)))
        state = started.state
        let claimed = try claim(state: state)
        let before = claimed.retired
        let running = try #require(started.projection?.canonicalTimer)
        do {
            _ = try controller.plan(
                .pauseTimer(at: running.anchorAt.addingTimeInterval(10)),
                from: snapshot(before, timer: running, dateOffset: 10)
            )
            Issue.record("stale Pause must not commit")
        } catch let admission as WorkspaceIntentAdmissionError {
            let diagnostics: WorkspaceMutationDiagnostics
            switch admission {
            case .coreRejected(let value):
                diagnostics = value
            case .invalidCoreResponse(let value):
                diagnostics = value
            case .ignoredRetarget(let value):
                diagnostics = value
            }
            #expect(diagnostics.category == .timerPause)
            #expect(diagnostics.provenance == WorkspaceIntentProvenance.current())
            #expect(diagnostics.provenance != "unknown")
            #expect(!diagnostics.publicMessage().contains("timer-R48AP01-pause"))
        }
    }

    @Test @MainActor
    func selectPlusRetargetMixedQueued() throws {
        let controller = makeController(timerID: "timer-R48AP01-retarget")
        let first = try #require(FocusTask(title: "First retarget"))
        let second = try #require(FocusTask(title: "Second retarget"))
        var state = PersistedTimerState.fresh()
        state.tasks = [first, second]
        state.knownTasks = [first, second]
        let started = try #require(try controller.plan(.startTimer, from: snapshot(state)))
        state = started.state
        let running = try #require(started.projection?.canonicalTimer)
        let selected = try #require(try controller.plan(.selectTask(first.id), from: snapshot(state, timer: running)))
        state = selected.state
        let claimed = try claimSelectedOnly(state: state)
        let before = claimed.retired
        let runningBefore = try #require(try controller.plan(.selectTask(second.id), from: snapshot(before, timer: running)))
        #expect(runningBefore.state.pendingSelectedTaskOperations.count == 2)
        #expect(runningBefore.state.pendingCommands.count == 2)
    }

    @Test @MainActor
    func staleNullHeadQueued() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state: state, controller: controller, minutes: 30)
        let claimed = try claim(state: state)
        var before = claimed.retired
        before.canonicalHeadWallMs = nil
        before.canonicalHeadCounter = nil
        let edited = try #require(try controller.plan(.setDurationMinutes(35, for: .focus), from: snapshot(before)))
        #expect(edited.state.pendingDurationOperations.count == 2)
    }

    @Test @MainActor
    func rollbackOnSameDurationNoOp() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state: state, controller: controller, minutes: 30)
        let before = state
        let result = try controller.plan(.setDurationMinutes(30, for: .focus), from: snapshot(state))
        #expect(result == nil)
        #expect(state == before)
    }

    @Test @MainActor
    func diagnosticsArePrivacySafe() throws {
        let diagnostics = WorkspaceMutationDiagnostics(
            category: .setDuration,
            coreReason: "workspace group failed retained-ledger admission",
            pendingCommands: 1,
            pendingTasks: 0,
            pendingDurations: 1,
            pendingAutoStart: 0,
            pendingSelected: 0,
            queued: 0,
            applied: 0,
            isIgnoredRetarget: false,
            provenance: WorkspaceIntentProvenance.current()
        )
        let message = diagnostics.publicMessage()
        #expect(message.contains("setDuration"))
        #expect(!message.contains("Queued upsert"))
        #expect(message.contains("core="))
    }
}
