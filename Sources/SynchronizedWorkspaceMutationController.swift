import Foundation

@MainActor
final class SynchronizedWorkspaceMutationController {
    struct Snapshot: Sendable {
        let state: PersistedTimerState
        let canonicalTimer: CanonicalTimer?
        let tasks: [FocusTask]
        let projectedAutoStartBreaks: Bool
        let projectedSelectedTaskID: UUID?
        let replicationMode: ReplicationMode
        let localDate: Date
        let trustedClockUptime: TimeInterval
        let isWorkspaceMutationBlocked: Bool
    }

    struct Requirements: Equatable, Sendable {
        var timerCommandIDs: Set<String> = []
        var taskOperationIDs: Set<String> = []
        var durationOperationIDs: Set<String> = []
        var autoStartOperationIDs: Set<String> = []
        var selectedTaskOperationIDs: Set<String> = []
    }

    enum Effect: Equatable, Sendable {
        case persist
        case persistAtomically(previous: PersistedTimerState, rebuildsOnRollback: Bool)
        case launchSync
        case setExplicitPhaseSelection(Bool)
        case clearCompletionAlert(timerID: String)
        case alarm(TimerSessionController.AlarmPlan, cancelReportsError: Bool)
    }

    struct Transition: Equatable, Sendable {
        let state: PersistedTimerState
        let projection: CoreProjectionOutput?
        let requirements: Requirements
        let effects: [Effect]
    }

    struct CommandIntent: Sendable {
        let type: CommandType
        let timerID: String
        let taskID: String?
        let phase: TimerPhase
        let duration: TimeInterval
        let elapsed: TimeInterval
    }

    struct PreparedMutation: Sendable {
        let state: PersistedTimerState
        let requirements: Requirements
    }

    enum Intent: Sendable {
        case selectPhase(TimerPhase)
        case selectTask(UUID?)
        case setAutoStartBreaks(Bool)
        case setDurationMinutes(Int, for: TimerPhase)
        case startTimer
        case pauseTimer(at: Date)
        case resumeTimer(at: Date)
        case cancelTimer(at: Date)
        case clearTimer
        case task(TaskOperationType, FocusTask)
        case command(CommandIntent)
        case commit(PreparedMutation)
    }

    private let timerSessionController: TimerSessionController
    private let timerIDProvider: @MainActor () -> String

    init(
        timerSessionController: TimerSessionController,
        timerIDProvider: @escaping @MainActor () -> String = {
            "timer-\(UUID().uuidString.lowercased())"
        }
    ) {
        self.timerSessionController = timerSessionController
        self.timerIDProvider = timerIDProvider
    }

    func plan(_ intent: Intent, from snapshot: Snapshot) throws -> Transition? {
        guard !snapshot.isWorkspaceMutationBlocked else { return nil }
        switch intent {
        case .selectPhase(let phase):
            return try planPhase(phase, snapshot: snapshot)
        case .selectTask(let taskID):
            return try planSelectedTask(taskID, snapshot: snapshot)
        case .setAutoStartBreaks(let enabled):
            return try planAutoStart(enabled, snapshot: snapshot)
        case .setDurationMinutes(let minutes, for: let phase):
            return try planDuration(minutes, phase: phase, snapshot: snapshot)
        case .startTimer:
            return try planStart(snapshot)
        case .pauseTimer(let date):
            return try planPause(at: date, snapshot: snapshot)
        case .resumeTimer(let date):
            return try planResume(at: date, snapshot: snapshot)
        case .cancelTimer(let date):
            return try planCancel(at: date, snapshot: snapshot)
        case .clearTimer:
            return try planClear(snapshot)
        case .task(let type, let task):
            return try planTask(type, task: task, snapshot: snapshot)
        case .command(let command):
            return try planCommand(command, snapshot: snapshot)
        case .commit(let mutation):
            return try synchronized(mutation.state, mutation.requirements, snapshot: snapshot)
        }
    }
}

private extension SynchronizedWorkspaceMutationController {
    func planPhase(_ phase: TimerPhase, snapshot: Snapshot) throws -> Transition {
        guard snapshot.state.hasValidPendingWireOperations else {
            throw AppError.invalidLocalClock
        }
        guard let timer = snapshot.canonicalTimer, !isActive(timer) else {
            var state = snapshot.state
            state.selectedPhaseGeneration = TimerSessionController.nextPhaseGeneration(
                after: state.selectedPhaseGeneration
            )
            state.settings.selectedPhase = phase
            state.hasExplicitPhaseSelection = true
            return local(state, effect: .persist)
        }
        let occurredAt = try occurrenceDate(snapshot)
        let command = try makeCommand(
            .clear,
            timer: timer,
            elapsed: timer.elapsed(at: snapshot.localDate),
            occurredAt: occurredAt,
            snapshot: snapshot
        )
        var state = command.state
        state.settings.selectedPhase = phase
        state.selectedPhaseGeneration = TimerSessionController.nextPhaseGeneration(
            after: state.selectedPhaseGeneration
        )
        state.hasExplicitPhaseSelection = true
        return try synchronized(
            state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot,
            afterSync: [cancelAlarm(timer.id, reportsError: false)]
        )
    }

    func planSelectedTask(_ taskID: UUID?, snapshot: Snapshot) throws -> Transition? {
        guard snapshot.state.hasValidPendingWireOperations,
              taskID != snapshot.projectedSelectedTaskID,
              taskID == nil || snapshot.tasks.contains(where: { $0.id == taskID }) else {
            return nil
        }
        var state = snapshot.state
        let occurredAt = try occurrenceDate(snapshot)
        let operationID = try appendSelectedTaskOperation(taskID, at: occurredAt, to: &state)
        return try synchronized(
            state,
            Requirements(selectedTaskOperationIDs: [operationID]),
            snapshot: snapshot
        )
    }

    func planAutoStart(_ enabled: Bool, snapshot: Snapshot) throws -> Transition? {
        guard enabled != snapshot.projectedAutoStartBreaks else { return nil }
        var state = snapshot.state
        let occurredAt = try occurrenceDate(snapshot)
        try state.advanceClock(at: occurredAt)
        let operationID = try state.reserveUuidV7()[0]
        state.pendingAutoStartOperations.append(AutoStartOperation(
            id: operationID,
            deviceId: state.deviceId,
            enabled: enabled,
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        ))
        return try synchronized(
            state,
            Requirements(autoStartOperationIDs: [operationID.uuidString.lowercased()]),
            snapshot: snapshot
        )
    }

    func planDuration(
        _ requestedMinutes: Int,
        phase: TimerPhase,
        snapshot: Snapshot
    ) throws -> Transition? {
        let minutes = min(180, max(1, requestedMinutes))
        let durationMs = Int64(minutes) * DurationValues.wireUnitMs
        guard snapshot.state.settings.durationMs(for: phase) != durationMs else { return nil }
        let occurredAt = try occurrenceDate(snapshot)
        var state = snapshot.state
        var commandIDs = Set<String>()
        var effects: [Effect] = []
        if let timer = snapshot.canonicalTimer, !isActive(timer) {
            let command = try makeCommand(
                .clear,
                timer: timer,
                elapsed: timer.elapsed(at: snapshot.localDate),
                occurredAt: occurredAt,
                snapshot: snapshot,
                state: state
            )
            state = command.state
            commandIDs.insert(command.command.id)
            effects.append(cancelAlarm(timer.id, reportsError: false))
        }
        try state.advanceClock(at: occurredAt)
        let operationID = "duration-operation-\(try state.reserveUuidV7()[0].uuidString.lowercased())"
        state.pendingDurationOperations.removeAll { $0.phase == phase }
        state.pendingDurationOperations.append(DurationOperation(
            id: operationID,
            phase: phase,
            durationMs: durationMs,
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        ))
        state.settings.setMinutes(minutes, for: phase)
        return try synchronized(
            state,
            Requirements(
                timerCommandIDs: commandIDs,
                durationOperationIDs: [operationID]
            ),
            snapshot: snapshot,
            afterSync: effects
        )
    }

    func planStart(_ snapshot: Snapshot) throws -> Transition? {
        guard snapshot.canonicalTimer.map(isActive) != true else { return nil }
        let phase = snapshot.state.settings.selectedPhase
        let duration = TimeInterval(snapshot.state.settings.durationMs(for: phase)) / 1_000
        let taskID = selectedTaskID(for: phase, snapshot: snapshot)
        let timerID = timerIDProvider()
        let command = try makeCommand(
            .start,
            timerID: timerID,
            taskID: taskID,
            phase: phase,
            duration: duration,
            elapsed: 0,
            snapshot: snapshot
        )
        let alarm = timerSessionController.alarmPlan(for: .schedule(
            timerID: timerID,
            phase: phase,
            duration: duration
        ))
        return try synchronized(
            command.state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot,
            afterSync: [
                .setExplicitPhaseSelection(false),
                .persist,
                .alarm(alarm, cancelReportsError: true)
            ]
        )
    }

    func planPause(at date: Date, snapshot: Snapshot) throws -> Transition? {
        guard let timer = snapshot.canonicalTimer, timer.status == .running else { return nil }
        let command = try makeCommand(
            .pause,
            timer: timer,
            elapsed: timer.elapsed(at: date),
            occurredAt: try occurrenceDate(snapshot),
            snapshot: snapshot
        )
        return try synchronized(
            command.state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot,
            afterSync: [.alarm(
                timerSessionController.alarmPlan(for: .pause(timerID: timer.id)),
                cancelReportsError: true
            )]
        )
    }

    func planResume(at date: Date, snapshot: Snapshot) throws -> Transition? {
        guard let timer = snapshot.canonicalTimer, timer.status == .paused else { return nil }
        let command = try makeCommand(
            .resume,
            timer: timer,
            elapsed: timer.elapsed(at: date),
            occurredAt: try occurrenceDate(snapshot),
            snapshot: snapshot
        )
        let alarm = timerSessionController.alarmPlan(for: .resume(
            timerID: timer.id,
            phase: timer.phase,
            duration: max(1, timer.remaining(at: date))
        ))
        return try synchronized(
            command.state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot,
            afterSync: [.alarm(alarm, cancelReportsError: true)]
        )
    }

    func planCancel(at date: Date, snapshot: Snapshot) throws -> Transition? {
        guard let timer = snapshot.canonicalTimer, isActive(timer) else { return nil }
        let occurredAt = try occurrenceDate(snapshot)
        let elapsed = timer.elapsed(at: date)
        let cancel = try makeCommand(
            .cancel,
            timer: timer,
            elapsed: elapsed,
            occurredAt: occurredAt,
            snapshot: snapshot
        )
        let clear = try makeCommand(
            .clear,
            timer: timer,
            elapsed: elapsed,
            occurredAt: occurredAt,
            snapshot: snapshot,
            state: cancel.state
        )
        return try synchronized(
            clear.state,
            Requirements(timerCommandIDs: [cancel.command.id, clear.command.id]),
            snapshot: snapshot,
            afterSync: [cancelAlarm(timer.id, reportsError: true)]
        )
    }

    func planClear(_ snapshot: Snapshot) throws -> Transition? {
        guard let timer = snapshot.canonicalTimer, !isActive(timer) else { return nil }
        let command = try makeCommand(
            .clear,
            timer: timer,
            elapsed: timer.elapsed(at: snapshot.localDate),
            occurredAt: try occurrenceDate(snapshot),
            snapshot: snapshot
        )
        return try synchronized(
            command.state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot,
            afterSync: [
                .clearCompletionAlert(timerID: timer.id),
                cancelAlarm(timer.id, reportsError: false)
            ]
        )
    }
}

private extension SynchronizedWorkspaceMutationController {
    func planTask(
        _ type: TaskOperationType,
        task: FocusTask,
        snapshot: Snapshot
    ) throws -> Transition {
        var state = snapshot.state
        let occurredAt = try occurrenceDate(snapshot)
        try state.advanceClock(at: occurredAt)
        let operationID = "task-operation-\(try state.reserveUuidV7()[0].uuidString.lowercased())"
        state.mergeKnownTasks([task])
        state.pendingTaskOperations.append(TaskOperation(
            id: operationID,
            taskId: task.id.uuidString.lowercased(),
            type: type,
            title: type == .upsert ? task.title : nil,
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        ))
        var selectedOperationIDs = Set<String>()
        if type == .delete, state.selectedTaskID == task.id {
            selectedOperationIDs.insert(try appendSelectedTaskOperation(
                nil,
                at: occurredAt,
                to: &state
            ))
        }
        return try synchronized(
            state,
            Requirements(
                taskOperationIDs: [operationID],
                selectedTaskOperationIDs: selectedOperationIDs
            ),
            snapshot: snapshot
        )
    }

    func planCommand(_ intent: CommandIntent, snapshot: Snapshot) throws -> Transition {
        let command = try makeCommand(
            intent.type,
            timerID: intent.timerID,
            taskID: intent.taskID,
            phase: intent.phase,
            duration: intent.duration,
            elapsed: intent.elapsed,
            snapshot: snapshot
        )
        return try synchronized(
            command.state,
            Requirements(timerCommandIDs: [command.command.id]),
            snapshot: snapshot
        )
    }

    func synchronized(
        _ state: PersistedTimerState,
        _ requirements: Requirements,
        snapshot: Snapshot,
        afterSync: [Effect] = []
    ) throws -> Transition {
        let output = try timerSessionController.project(
            state,
            replicationMode: snapshot.replicationMode,
            physicalNow: snapshot.localDate
        )
        guard requirements.areSatisfied(by: output) else {
            throw SharedCoreError.invalidResponse(
                "new synchronized mutation did not win Core projection"
            )
        }
        return Transition(
            state: state,
            projection: output,
            requirements: requirements,
            effects: [
                .persistAtomically(previous: snapshot.state, rebuildsOnRollback: true),
                .launchSync
            ] + afterSync
        )
    }

    func local(_ state: PersistedTimerState, effect: Effect) -> Transition {
        Transition(
            state: state,
            projection: nil,
            requirements: Requirements(),
            effects: [effect]
        )
    }

    func occurrenceDate(_ snapshot: Snapshot) throws -> Date {
        try snapshot.state.trustedOccurrenceDate(
            for: snapshot.localDate,
            uptime: snapshot.trustedClockUptime
        )
    }

    func selectedTaskID(for phase: TimerPhase, snapshot: Snapshot) -> String? {
        guard phase == .focus, let selected = snapshot.state.selectedTaskID else { return nil }
        return snapshot.tasks.first(where: { $0.id == selected })?
            .id.uuidString.lowercased()
    }

    func isActive(_ timer: CanonicalTimer) -> Bool {
        timer.status == .running || timer.status == .paused
    }

    func cancelAlarm(_ timerID: String, reportsError: Bool) -> Effect {
        .alarm(
            timerSessionController.alarmPlan(for: .cancel(timerID: timerID)),
            cancelReportsError: reportsError
        )
    }
}

private extension SynchronizedWorkspaceMutationController {
    func makeCommand(
        _ type: CommandType,
        timer: CanonicalTimer,
        elapsed: TimeInterval,
        occurredAt: Date,
        snapshot: Snapshot,
        state: PersistedTimerState? = nil
    ) throws -> TimerSessionController.CommandTransition {
        try makeCommand(
            type,
            timerID: timer.id,
            taskID: nil,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed,
            occurredAt: occurredAt,
            snapshot: snapshot,
            state: state
        )
    }

    func makeCommand(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval,
        snapshot: Snapshot,
        state: PersistedTimerState? = nil
    ) throws -> TimerSessionController.CommandTransition {
        try timerSessionController.makeCommand(
            .init(
                type: type,
                timerID: timerID,
                taskID: taskID,
                phase: phase,
                duration: duration,
                elapsed: elapsed,
                occurredAt: try occurrenceDate(snapshot),
                localDate: snapshot.localDate
            ),
            state: state ?? snapshot.state
        )
    }

    func makeCommand(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval,
        occurredAt: Date,
        snapshot: Snapshot,
        state: PersistedTimerState? = nil
    ) throws -> TimerSessionController.CommandTransition {
        try timerSessionController.makeCommand(
            .init(
                type: type,
                timerID: timerID,
                taskID: taskID,
                phase: phase,
                duration: duration,
                elapsed: elapsed,
                occurredAt: occurredAt,
                localDate: snapshot.localDate
            ),
            state: state ?? snapshot.state
        )
    }

    func appendSelectedTaskOperation(
        _ selectedTaskID: UUID?,
        at occurredAt: Date,
        to state: inout PersistedTimerState
    ) throws -> String {
        try state.advanceClock(at: occurredAt)
        let operationID = try state.reserveUuidV7()[0]
        state.pendingSelectedTaskOperations.append(SelectedTaskOperation(
            id: operationID,
            deviceId: state.deviceId,
            taskId: selectedTaskID?.uuidString.lowercased(),
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        ))
        state.selectedTaskID = selectedTaskID
        return operationID.uuidString.lowercased()
    }
}

private extension SynchronizedWorkspaceMutationController.Requirements {
    func areSatisfied(by output: CoreProjectionOutput) -> Bool {
        timerCommandIDs.allSatisfy {
            output.timerOutcomes[$0]?.outcome == .applied
        } && taskOperationIDs.allSatisfy {
            output.winningOperationIds.tasks.values.contains($0)
        } && durationOperationIDs.allSatisfy {
            output.winningOperationIds.durations.values.contains($0)
        } && autoStartOperationIDs.allSatisfy {
            output.winningOperationIds.autoStart == $0
        } && selectedTaskOperationIDs.allSatisfy {
            output.winningOperationIds.selectedTask == $0
        }
    }
}
