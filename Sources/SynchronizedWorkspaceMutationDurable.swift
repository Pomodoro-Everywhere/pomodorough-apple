import Foundation
import OSLog

extension SynchronizedWorkspaceMutationController {
    func synchronized(
        _ state: PersistedTimerState,
        _ requirements: Requirements,
        snapshot: Snapshot,
        afterSync: [Effect] = [],
        kind: WorkspaceIntentKind? = nil,
        category: WorkspaceIntentCategory? = nil
    ) throws -> Transition {
        do {
            let output = try timerSessionController.project(
                state,
                replicationMode: snapshot.replicationMode,
                physicalNow: snapshot.localDate
            )
            if requirements.areSatisfied(by: output) {
                return Transition(
                    state: state,
                    projection: output,
                    requirements: requirements,
                    effects: [.persistAtomically(previous: snapshot.state, rebuildsOnRollback: true), .launchSync] + afterSync
                )
            }
        } catch {
            throw error
        }
        guard let kind, let category else {
            throw SharedCoreError.invalidResponse("new synchronized mutation did not win Core projection")
        }
        return try durableCommit(kind: kind, category: category, snapshot: snapshot, afterSync: afterSync)
    }

    func durableCommit(
        kind: WorkspaceIntentKind,
        category: WorkspaceIntentCategory,
        snapshot: Snapshot,
        afterSync: [Effect]
    ) throws -> Transition {
        let plan = try admission.plan(kind: kind, category: category, snapshot: snapshot)
        let effects = remappedEffects(kind: kind, plan: plan, afterSync: afterSync, snapshot: snapshot)
        return Transition(
            state: plan.state,
            projection: plan.projection,
            requirements: plan.requirements,
            effects: effects
        )
    }

    func remappedEffects(
        kind: WorkspaceIntentKind,
        plan: WorkspaceIntentPlan,
        afterSync: [Effect],
        snapshot: Snapshot
    ) -> [Effect] {
        let base: [Effect] = [.persistAtomically(previous: snapshot.state, rebuildsOnRollback: true), .launchSync]
        guard isStart(kind) else { return base + afterSync }
        guard let timerID = plan.state.pendingCommands.last?.timerId else { return base + afterSync }
        return base + afterSync.map { remappedStartEffect($0, timerID: timerID) }
    }

    func isStart(_ kind: WorkspaceIntentKind) -> Bool {
        if case .start = kind { return true }
        return false
    }

    func remappedStartEffect(_ effect: Effect, timerID: String) -> Effect {
        switch effect {
        case .alarm(let plan):
            let actions = plan.actions.map { remappedStartAlarm($0, timerID: timerID) }
            return .alarm(TimerSessionController.AlarmPlan(actions: actions))
        default:
            return effect
        }
    }

    func remappedStartAlarm(_ action: TimerSessionController.AlarmAction, timerID: String) -> TimerSessionController.AlarmAction {
        switch action {
        case .schedule(_, let phase, let duration):
            return .schedule(timerID: timerID, phase: phase, duration: duration)
        default:
            return action
        }
    }

    func intentKind(for intent: Intent) -> (WorkspaceIntentKind?, WorkspaceIntentCategory?) {
        switch intent {
        case .selectPhase(let phase):
            return (.selectPhase(phase), .phase)
        case .selectTask(let taskID):
            return (.selectTask(taskID?.uuidString.lowercased()), .selectTask)
        case .setAutoStartBreaks(let enabled):
            return (.setAutoStart(enabled), .setAutoStart)
        case .setDurationMinutes(let minutes, for: let phase):
            return (.setDuration(phase, minutes), .setDuration)
        case .startTimer:
            return (.start, .timerStart)
        case .pauseTimer:
            return (.pause, .timerPause)
        case .resumeTimer:
            return (.resume, .timerResume)
        case .cancelTimer:
            return (.cancelAndClear, .timerCancel)
        case .clearTimer:
            return (.clear, .timerClear)
        case .task(let type, let task):
            return taskIntentKind(type: type, task: task)
        case .command(let command):
            return commandIntentKind(command: command)
        case .commit:
            return (nil, nil)
        }
    }

    func taskIntentKind(
        type: TaskOperationType,
        task: FocusTask
    ) -> (WorkspaceIntentKind?, WorkspaceIntentCategory?) {
        switch type {
        case .upsert:
            return (.upsertTask(task.title), .taskUpsert)
        case .delete:
            return (.deleteTask(task.id.uuidString.lowercased()), .taskDelete)
        }
    }

    func commandIntentKind(
        command: CommandIntent
    ) -> (WorkspaceIntentKind?, WorkspaceIntentCategory?) {
        switch command.type {
        case .start:
            return (.start, .timerStart)
        case .pause:
            return (.pause, .timerPause)
        case .resume:
            return (.resume, .timerResume)
        case .cancel:
            return (.cancelAndClear, .timerCancel)
        case .clear:
            return (.clear, .timerClear)
        case .retarget:
            return (.selectTask(command.taskID), .selectTask)
        case .finish:
            return (nil, nil)
        }
    }
}
