import Foundation

enum IrohRoomProjection {
    private struct ProjectionOperations {
        var knownTasks: [UUID: FocusTask]
        var commands: [CoreTimerCommand] = []
        var taskOperations: [CoreTaskOperation] = []
        var durationOperations: [CoreDurationOperation] = []
        var autoStartOperations: [CoreAutoStartOperation] = []
        var selectedTaskOperations: [CoreSelectedTaskOperation] = []
        var nativeCommands: [String: TimerCommand] = [:]
        var deviceByCommand: [String: String] = [:]
        var timerStarters: [String: String] = [:]

        init(genesis: IrohGenesis) {
            knownTasks = Dictionary(uniqueKeysWithValues: genesis.tasks.map { ($0.id, $0) })
        }

        mutating func ingest(_ record: IrohOperationRecord) throws {
            switch record.payload {
            case .genesis:
                throw IrohProtocolError.invalidMessage("room contains an extra genesis record")
            case .timer(let command):
                commands.append(CoreTimerCommand(command, deviceId: record.deviceId))
                nativeCommands[command.id] = command
                deviceByCommand[command.id] = record.deviceId
                if command.type == .start { timerStarters[command.timerId] = record.deviceId }
            case .task(let operation):
                taskOperations.append(CoreTaskOperation(operation, deviceId: record.deviceId))
                if operation.type == .upsert,
                   let title = operation.title,
                   let task = FocusTask(title: title) {
                    knownTasks[task.id] = task
                }
            case .duration(let operation):
                durationOperations.append(CoreDurationOperation(operation, deviceId: record.deviceId))
            case .autoStart(let operation):
                autoStartOperations.append(CoreAutoStartOperation(operation, deviceId: record.deviceId))
            case .selectedTask(let operation):
                selectedTaskOperations.append(CoreSelectedTaskOperation(operation, deviceId: record.deviceId))
            }
        }

        var pending: CoreProjectionPending {
            CoreProjectionPending(
                commands: commands,
                taskOperations: taskOperations,
                durationOperations: durationOperations,
                autoStartOperations: autoStartOperations,
                selectedTaskOperations: selectedTaskOperations
            )
        }
    }

    static func project(
        _ workspace: IrohRoomWorkspace,
        at projectionDate: Date = .now
    ) throws -> PersistedTimerState {
        guard workspace.conflict == nil,
              let genesis = workspace.genesis,
              genesis.isValid else {
            throw IrohProtocolError.invalidMessage("room genesis is missing or invalid")
        }
        let operations = workspace.records.map(\.record).filter { $0.domain != .genesis }.sorted(by: precedes)
        var collected = ProjectionOperations(genesis: genesis)
        for record in operations { try collected.ingest(record) }
        let output = try applySharedProjection(genesis, pending: collected.pending, at: projectionDate)
        var timer = restoreIntentDevice(output.canonicalTimer, devices: collected.deviceByCommand)
        var history = output.history
        var tasks = output.tasks
        timer = restoreTerminalTimer(
            timer,
            history: history,
            output: output,
            genesis: genesis,
            operations: collected
        )
        tasks.sort(by: taskPrecedes)
        history.sort(by: historyPrecedes)
        return projectedState(
            workspace,
            genesis: genesis,
            operations: operations,
            collected: collected,
            output: output,
            timer: timer,
            history: history,
            tasks: tasks
        )
    }

    private static func applySharedProjection(
        _ genesis: IrohGenesis,
        pending: CoreProjectionPending,
        at projectionDate: Date
    ) throws -> CoreProjectionOutput {
        do {
            return try SharedCore.bundled().applyProjection(CoreProjectionInput(
                base: CoreProjectionBase(
                    canonicalTimer: genesis.canonicalTimer,
                    history: genesis.history,
                    tasks: genesis.tasks,
                    durationsMs: genesis.durationsMs,
                    autoStartBreaks: genesis.autoStartBreaks,
                    selectedTaskId: genesis.selectedTaskId
                ),
                pending: pending,
                now: projectionDate
            ))
        } catch {
            throw IrohProtocolError.invalidMessage(
                "shared-core room projection failed: \(error.localizedDescription)"
            )
        }
    }

    private static func restoreIntentDevice(
        _ timer: CanonicalTimer?,
        devices: [String: String]
    ) -> CanonicalTimer? {
        timer.map { timer in
            guard let intent = timer.lastIntent, let deviceID = devices[intent.commandId] else {
                return timer
            }
            return CanonicalTimer(
                id: timer.id,
                taskId: timer.taskId,
                phase: timer.phase,
                status: timer.status,
                plannedDurationMs: timer.plannedDurationMs,
                elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                anchorAt: timer.anchorAt,
                startedByDeviceId: timer.startedByDeviceId,
                lastIntent: TimerIntent(
                    type: intent.type,
                    commandId: intent.commandId,
                    occurredAt: intent.occurredAt,
                    deviceId: deviceID
                )
            )
        }
    }

    private static func restoreTerminalTimer(
        _ timer: CanonicalTimer?,
        history: [HistoryItem],
        output: CoreProjectionOutput,
        genesis: IrohGenesis,
        operations: ProjectionOperations
    ) -> CanonicalTimer? {
        guard let appliedCommand = operations.commands.last(where: {
            output.timerOutcomes[$0.id]?.outcome == .applied
        }) else {
            guard let genesisTimer = genesis.canonicalTimer else { return timer }
            switch genesisTimer.status {
            case .completed, .cancelled, .superseded:
                return genesisTimer
            case .running, .paused:
                return timer
            }
        }
        if let timer { return timer }
        guard appliedCommand.type != .clear,
        let terminal = history.first(where: {
            $0.timerId == appliedCommand.timerId && $0.commandId == appliedCommand.id
        }),
        let status = CanonicalTimer.Status(rawValue: terminal.status),
        let endedAt = terminal.completedAt ?? terminal.endedAt else { return nil }
        let command = operations.nativeCommands[appliedCommand.id]
        return CanonicalTimer(
            id: terminal.timerId,
            taskId: terminal.taskId,
            phase: terminal.phase,
            status: status,
            plannedDurationMs: terminal.plannedDurationMs,
            elapsedAtAnchorMs: terminalElapsed(status: status, item: terminal, command: command),
            anchorAt: endedAt,
            startedByDeviceId: operations.timerStarters[terminal.timerId]
                ?? genesis.canonicalTimer?.startedByDeviceId,
            lastIntent: command.map {
                TimerIntent(
                    type: $0.type,
                    commandId: $0.id,
                    occurredAt: $0.occurredAt,
                    deviceId: operations.deviceByCommand[$0.id]
                )
            }
        )
    }

    private static func terminalElapsed(
        status: CanonicalTimer.Status,
        item: HistoryItem,
        command: TimerCommand?
    ) -> Int64 {
        status == .completed
            ? item.plannedDurationMs
            : min(item.plannedDurationMs, max(0, command?.observedElapsedMs ?? 0))
    }

    private static func projectedState(
        _ workspace: IrohRoomWorkspace,
        genesis: IrohGenesis,
        operations: [IrohOperationRecord],
        collected: ProjectionOperations,
        output: CoreProjectionOutput,
        timer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask]
    ) -> PersistedTimerState {
        var state = workspace.roomState
        state.canonicalTimer = timer
        state.history = history
        state.tasks = tasks
        state.knownTasks = Array(collected.knownTasks.values)
        state.settings.durationsMs = output.durationsMs
        state.autoStartBreaks = output.autoStartBreaks
        state.selectedTaskID = output.selectedTaskId.flatMap(UUID.init(uuidString:))
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        state.pendingAutoStartOperations = []
        state.pendingSelectedTaskOperations = []
        state.provisionalBreaks = []
        let maximum = ([
            (genesis.hlcWallMs, genesis.hlcCounter),
            (state.hlcWallMs, state.hlcCounter),
        ] + operations.map(\.order)).max { $0 < $1 } ?? (0, 0)
        state.hlcWallMs = maximum.0
        state.hlcCounter = maximum.1
        return state
    }

    static func precedes(_ lhs: IrohOperationRecord, _ rhs: IrohOperationRecord) -> Bool {
        if lhs.order.wallMs != rhs.order.wallMs { return lhs.order.wallMs < rhs.order.wallMs }
        if lhs.order.counter != rhs.order.counter { return lhs.order.counter < rhs.order.counter }
        if lhs.deviceId != rhs.deviceId {
            return IrohProtocolV1.utf8Precedes(lhs.deviceId, rhs.deviceId)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }

    private static func taskPrecedes(_ lhs: FocusTask, _ rhs: FocusTask) -> Bool {
        if lhs.title != rhs.title {
            return IrohProtocolV1.utf8Precedes(lhs.title, rhs.title)
        }
        return IrohProtocolV1.utf8Precedes(
            lhs.id.uuidString.lowercased(),
            rhs.id.uuidString.lowercased()
        )
    }

    private static func historyPrecedes(_ lhs: HistoryItem, _ rhs: HistoryItem) -> Bool {
        let lhsDate = lhs.completedAt ?? lhs.endedAt ?? .distantPast
        let rhsDate = rhs.completedAt ?? rhs.endedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return IrohProtocolV1.utf8Precedes(lhs.timerId, rhs.timerId)
    }
}
