import Foundation

struct LegacyTaskMigrationResult: Equatable, Sendable {
    let enqueuedOperationIDs: [String]
}

struct LegacyDurationMigrationResult: Equatable, Sendable {
    let enqueuedOperationIDs: [String]
}

struct LegacyOperationMigrationResult: Equatable, Sendable {
    let didMigrate: Bool
    let operationID: UUID?
}

struct LegacyTimerOwnershipMigrationResult: Equatable, Sendable {
    let didMigrate: Bool
    let timerID: String?
}

enum PersistedLegacyMigration {
    static func migrateTasks(
        _ legacy: LocalTaskState,
        state: inout PersistedTimerState,
        at date: Date
    ) throws -> LegacyTaskMigrationResult {
        mergeTaskCatalog(legacy, into: &state)
        restoreTaskMetadata(legacy, state: &state)
        let operationIDs = try enqueueTasks(legacy.tasks, state: &state, at: date)
        return LegacyTaskMigrationResult(enqueuedOperationIDs: operationIDs)
    }

    static func restoreTaskMetadata(_ legacy: LocalTaskState, state: inout PersistedTimerState) {
        state.mergeKnownTasks(legacy.tasks + Array(legacy.assignments.values))
        state.legacyTaskAssignments.merge(legacy.assignments.mapValues(\.id)) { _, migrated in migrated }
        state.pendingCommands = assignTasks(to: state.pendingCommands, assignments: legacy.assignments)
        state.canonicalTimer = assignTask(to: state.canonicalTimer, assignments: legacy.assignments)
        state.history = assignTasks(to: state.history, assignments: legacy.assignments)
    }

    static func migrateDurationSettings(
        state: inout PersistedTimerState
    ) -> LegacyDurationMigrationResult {
        var operationIDs: [String] = []
        for phase in TimerPhase.allCases {
            let durationMs = state.settings.durationMs(for: phase)
            guard durationMs != DurationValues.defaults.durationMs(for: phase) else { continue }
            let operation = DurationOperation(
                id: "duration-operation-\(UUID().uuidString.lowercased())",
                phase: phase,
                durationMs: durationMs,
                occurredAt: Date(timeIntervalSince1970: 0),
                hlcWallMs: 0,
                hlcCounter: 0
            )
            state.pendingDurationOperations.append(operation)
            operationIDs.append(operation.id)
        }
        return LegacyDurationMigrationResult(enqueuedOperationIDs: operationIDs)
    }

    static func migrateAutoStartBreaks(
        explicitlySet: Bool,
        state: inout PersistedTimerState,
        at date: Date
    ) throws -> LegacyOperationMigrationResult {
        guard state.settings.autoStartBreaks || explicitlySet else {
            return LegacyOperationMigrationResult(didMigrate: false, operationID: nil)
        }
        try state.advanceClock(at: date)
        let operation = AutoStartOperation(
            id: UUID(),
            deviceId: state.deviceId,
            enabled: state.settings.autoStartBreaks,
            occurredAt: date,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
        state.pendingAutoStartOperations.append(operation)
        return LegacyOperationMigrationResult(didMigrate: true, operationID: operation.id)
    }

    static func migrateSelectedTask(
        state: inout PersistedTimerState,
        at date: Date
    ) throws -> LegacyOperationMigrationResult {
        guard let selectedTaskID = state.selectedTaskID,
              PersistedQueueReconciliation.applyingTaskOperations(
                  state.pendingTaskOperations,
                  to: state.tasks
              ).contains(where: { $0.id == selectedTaskID }) else {
            return LegacyOperationMigrationResult(didMigrate: false, operationID: nil)
        }
        try state.advanceClock(at: date)
        let operation = SelectedTaskOperation(
            id: try state.reserveUuidV7()[0],
            deviceId: state.deviceId,
            taskId: selectedTaskID.uuidString.lowercased(),
            occurredAt: date,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
        state.pendingSelectedTaskOperations.append(operation)
        return LegacyOperationMigrationResult(didMigrate: true, operationID: operation.id)
    }

    static func migrateTimerOwnership(
        state: inout PersistedTimerState
    ) -> LegacyTimerOwnershipMigrationResult {
        guard let timer = state.canonicalTimer,
              timer.status == .running || timer.status == .paused,
              state.localTimerOwners[timer.id] == nil,
              !state.pendingCommands.contains(where: {
                  $0.type == .start && $0.timerId == timer.id
              }) else {
            return LegacyTimerOwnershipMigrationResult(didMigrate: false, timerID: nil)
        }
        let owner = timer.startedByDeviceId ?? {
            guard let intent = timer.lastIntent, intent.type == .start else { return nil }
            return intent.deviceId
        }()
        guard owner == state.deviceId else {
            return LegacyTimerOwnershipMigrationResult(didMigrate: false, timerID: nil)
        }
        state.localTimerOwners[timer.id] = state.deviceId
        return LegacyTimerOwnershipMigrationResult(didMigrate: true, timerID: timer.id)
    }

    private static func mergeTaskCatalog(
        _ legacy: LocalTaskState,
        into state: inout PersistedTimerState
    ) {
        for task in legacy.tasks where !state.tasks.contains(where: { $0.id == task.id }) {
            state.tasks.append(task)
        }
        if let selected = legacy.selectedTaskID,
           state.tasks.contains(where: { $0.id == selected }) {
            state.selectedTaskID = selected
        }
    }

    private static func assignTasks(
        to commands: [TimerCommand],
        assignments: [String: FocusTask]
    ) -> [TimerCommand] {
        commands.map { command in
            guard command.taskId == nil,
                  command.type == .start,
                  let task = assignments[command.timerId] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: task.id.uuidString.lowercased(),
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: command.occurredAt,
                hlcWallMs: command.hlcWallMs,
                hlcCounter: command.hlcCounter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
    }

    private static func assignTask(
        to canonical: CanonicalTimer?,
        assignments: [String: FocusTask]
    ) -> CanonicalTimer? {
        guard let timer = canonical,
              timer.taskId == nil,
              let task = assignments[timer.id] else { return canonical }
        return CanonicalTimer(
            id: timer.id,
            taskId: task.id.uuidString.lowercased(),
            phase: timer.phase,
            status: timer.status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
            anchorAt: timer.anchorAt,
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: timer.lastIntent
        )
    }

    private static func assignTasks(
        to history: [HistoryItem],
        assignments: [String: FocusTask]
    ) -> [HistoryItem] {
        history.map { item in
            guard item.taskId == nil,
                  let task = assignments[item.timerId] else { return item }
            return HistoryItem(
                id: item.id,
                timerId: item.timerId,
                commandId: item.commandId,
                taskId: task.id.uuidString.lowercased(),
                phase: item.phase,
                status: item.status,
                plannedDurationMs: item.plannedDurationMs,
                completedAt: item.completedAt,
                endedAt: item.endedAt
            )
        }
    }

    private static func enqueueTasks(
        _ tasks: [FocusTask],
        state: inout PersistedTimerState,
        at date: Date
    ) throws -> [String] {
        var operationIDs: [String] = []
        for task in tasks where !state.pendingTaskOperations.contains(where: {
            $0.type == .upsert && UUID(uuidString: $0.taskId) == task.id
        }) {
            try state.advanceClock(at: date)
            let operationID = try state.reserveUuidV7()[0]
            let operation = TaskOperation(
                id: "task-operation-\(operationID.uuidString.lowercased())",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: date,
                hlcWallMs: state.hlcWallMs,
                hlcCounter: state.hlcCounter
            )
            state.pendingTaskOperations.append(operation)
            operationIDs.append(operation.id)
        }
        return operationIDs
    }
}
