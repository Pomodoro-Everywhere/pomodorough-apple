import Foundation

struct PersistedPendingOperationQueue: Equatable, Sendable {
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]
    let selectedTaskOperations: [SelectedTaskOperation]

    init(state: PersistedTimerState) {
        commands = state.pendingCommands
        taskOperations = state.pendingTaskOperations
        durationOperations = state.pendingDurationOperations
        autoStartOperations = state.pendingAutoStartOperations
        selectedTaskOperations = state.pendingSelectedTaskOperations
    }

    init(
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation],
        selectedTaskOperations: [SelectedTaskOperation]
    ) {
        self.commands = commands
        self.taskOperations = taskOperations
        self.durationOperations = durationOperations
        self.autoStartOperations = autoStartOperations
        self.selectedTaskOperations = selectedTaskOperations
    }

    func hasValidOperationsAndIdentity(deviceID: String) -> Bool {
        commands.allSatisfy(\.isValid)
            && taskOperations.allSatisfy(\.isValid)
            && durationOperations.allSatisfy(\.isValid)
            && autoStartOperations.allSatisfy { $0.isValid && $0.deviceId == deviceID }
            && selectedTaskOperations.allSatisfy { $0.isValid && $0.deviceId == deviceID }
            && Set(commands.map(\.id)).count == commands.count
            && Set(commands.map(\.deviceSequence)).count == commands.count
            && Set(taskOperations.map(\.id)).count == taskOperations.count
            && Set(durationOperations.map(\.id)).count == durationOperations.count
            && Set(autoStartOperations.map(\.id)).count == autoStartOperations.count
            && Set(selectedTaskOperations.map(\.id)).count == selectedTaskOperations.count
    }

    var queuedUUIDv7Payloads: [UUID] {
        commands.compactMap { UUIDv7.payload(from: $0.id) }
            + taskOperations.compactMap { UUIDv7.payload(from: $0.id) }
            + durationOperations.compactMap { UUIDv7.payload(from: $0.id) }
            + autoStartOperations.compactMap { UUIDv7.payload(from: $0.id.uuidString) }
            + selectedTaskOperations.compactMap { UUIDv7.payload(from: $0.id.uuidString) }
    }

}

struct DurationQueueReconciliationResult: Equatable, Sendable {
    let pendingOperations: [DurationOperation]
    let durations: DurationValues
}

struct AutoStartQueueReconciliationResult: Equatable, Sendable {
    let pendingOperations: [AutoStartOperation]
    let value: Bool
}

struct SelectedTaskQueueReconciliationResult: Equatable, Sendable {
    let pendingOperations: [SelectedTaskOperation]
    let selectedTaskID: UUID?
}

enum PersistedQueueReconciliation {
    static func reconcileDurations(
        canonical: DurationValues,
        pending: [DurationOperation],
        sent: [DurationOperation],
        acknowledgements: [DurationAcknowledgement]
    ) throws -> DurationQueueReconciliationResult {
        let sentIDs = sent.map(\.id)
        let acknowledgedIDs = acknowledgements.map(\.operationId)
        guard canonical.isValid,
              sent.allSatisfy(\.isValid),
              AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: acknowledgedIDs) else {
            throw AppError.invalidResponse
        }
        let sentIDSet = Set(sentIDs)
        let acknowledgedIDSet = Set(acknowledgedIDs)
        let retained = pending.filter {
            !(sentIDSet.contains($0.id) && acknowledgedIDSet.contains($0.id))
        }
        return DurationQueueReconciliationResult(
            pendingOperations: retained,
            durations: applyingDurationOperations(retained, to: canonical)
        )
    }

    static func reconcileAutoStart(
        canonical: Bool,
        deviceID: String,
        pending: [AutoStartOperation],
        sent: [AutoStartOperation],
        acknowledgements: [AutoStartAcknowledgement]
    ) throws -> AutoStartQueueReconciliationResult {
        let sentIDs = sent.map(\.id)
        let acknowledgedIDs = acknowledgements.map(\.operationId)
        guard sent.allSatisfy({ $0.isValid && $0.deviceId == deviceID }),
              AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: acknowledgedIDs) else {
            throw AppError.invalidResponse
        }
        let acknowledgedIDSet = Set(acknowledgedIDs)
        return AutoStartQueueReconciliationResult(
            pendingOperations: pending.filter { !acknowledgedIDSet.contains($0.id) },
            value: canonical
        )
    }

    static func reconcileSelectedTask(
        canonicalTaskID rawCanonicalTaskID: String?,
        canonicalTasks: [FocusTask],
        deviceID: String,
        pending: [SelectedTaskOperation],
        sent: [SelectedTaskOperation],
        acknowledgements: [SelectedTaskAcknowledgement]
    ) throws -> SelectedTaskQueueReconciliationResult {
        let canonicalTaskID = rawCanonicalTaskID.flatMap(UUID.init(uuidString:))
        let sentIDs = sent.map(\.id)
        let acknowledgedIDs = acknowledgements.map(\.operationId)
        guard hasValidCanonicalSelection(rawCanonicalTaskID, id: canonicalTaskID, tasks: canonicalTasks),
              sent.allSatisfy({ $0.isValid && $0.deviceId == deviceID }),
              AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: acknowledgedIDs) else {
            throw AppError.invalidResponse
        }
        let acknowledgedIDSet = Set(acknowledgedIDs)
        let retained = pending.filter { !acknowledgedIDSet.contains($0.id) }
        return SelectedTaskQueueReconciliationResult(
            pendingOperations: retained,
            selectedTaskID: applyingSelectedTaskOperations(retained, to: canonicalTaskID)
        )
    }

    static func applyingTaskOperations(
        _ operations: [TaskOperation],
        to baseTasks: [FocusTask]
    ) -> [FocusTask] {
        operations.sorted(by: taskOperationOrder).reduce(into: baseTasks) { tasks, operation in
            guard let taskID = UUID(uuidString: operation.taskId) else { return }
            switch operation.type {
            case .delete:
                tasks.removeAll { $0.id == taskID }
            case .upsert:
                guard let title = operation.title,
                      let task = FocusTask(title: title),
                      task.id == taskID else { return }
                tasks.removeAll { $0.id == taskID }
                tasks.append(task)
            }
        }
    }

    static func localProjection(
        of commands: [TimerCommand],
        localDates: [String: Date]
    ) -> [TimerCommand] {
        commands.map { command in
            guard let localDate = localDates[command.id] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: command.taskId,
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: localDate,
                hlcWallMs: command.hlcWallMs,
                hlcCounter: command.hlcCounter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
    }

    static func retainedLocalCommandDates(
        _ dates: [String: Date],
        pendingCommands: [TimerCommand]
    ) -> [String: Date] {
        let pendingIDs = Set(pendingCommands.map(\.id))
        return dates.filter { pendingIDs.contains($0.key) }
    }

    private static func applyingDurationOperations(
        _ operations: [DurationOperation],
        to base: DurationValues
    ) -> DurationValues {
        operations.sorted(by: durationOperationOrder).reduce(into: base) { durations, operation in
            guard operation.isValid else { return }
            durations.setDurationMs(operation.durationMs, for: operation.phase)
        }
    }

    private static func applyingSelectedTaskOperations(
        _ operations: [SelectedTaskOperation],
        to base: UUID?
    ) -> UUID? {
        operations.sorted(by: selectedTaskOperationOrder).reduce(base) { selectedTaskID, operation in
            guard operation.isValid else { return selectedTaskID }
            return operation.taskId.flatMap(UUID.init(uuidString:))
        }
    }

    private static func hasValidCanonicalSelection(
        _ rawID: String?,
        id: UUID?,
        tasks: [FocusTask]
    ) -> Bool {
        rawID == nil || id.map { selected in
            tasks.contains { $0.id == selected }
        } == true
    }

    private static func taskOperationOrder(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }

    private static func durationOperationOrder(
        _ lhs: DurationOperation,
        _ rhs: DurationOperation
    ) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }

    private static func selectedTaskOperationOrder(
        _ lhs: SelectedTaskOperation,
        _ rhs: SelectedTaskOperation
    ) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }

}
