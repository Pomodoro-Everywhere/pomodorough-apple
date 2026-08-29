import Foundation

@MainActor
final class TimerSessionController {
    struct CommandRequest: Sendable {
        let type: CommandType
        let timerID: String
        let taskID: String?
        let phase: TimerPhase
        let duration: TimeInterval
        let elapsed: TimeInterval
        let occurredAt: Date
        let localDate: Date
    }

    struct CommandTransition: Sendable {
        var state: PersistedTimerState
        let command: TimerCommand
    }

    struct AutomaticBreak: Sendable {
        let timerID: String
        let phase: TimerPhase
        let duration: TimeInterval
    }

    struct FinishTransition: Sendable {
        var state: PersistedTimerState
        let command: TimerCommand
        let nextPhase: TimerPhase
        let queueAutoBreak: Bool
        let occurredAt: Date
        let localDate: Date
    }

    struct AutomaticBreakTransition: Sendable {
        var state: PersistedTimerState
        let automaticBreak: AutomaticBreak
        let command: TimerCommand
    }

    struct CompletionDecision: Sendable {
        let completedAt: Date
        let selectedPhase: TimerPhase?
        let generatedBreakPhase: TimerPhase?
    }

    enum AlarmAction: Equatable, Sendable {
        case schedule(timerID: String, phase: TimerPhase, duration: TimeInterval)
        case pause(timerID: String)
        case resume(timerID: String, phase: TimerPhase, duration: TimeInterval)
        case cancel(timerID: String)
    }

    struct AlarmPlan: Equatable, Sendable {
        let actions: [AlarmAction]

        static let none = AlarmPlan(actions: [])
    }

    private let sharedCoreProvider: @MainActor () throws -> SharedCore
    private var sharedCore: SharedCore?

    init(sharedCoreProvider: @escaping @MainActor () throws -> SharedCore) {
        self.sharedCoreProvider = sharedCoreProvider
    }

    func makeCommand(
        _ request: CommandRequest,
        state: PersistedTimerState
    ) throws -> CommandTransition {
        var updated = state
        let core = try loadCore()
        try updated.advanceClock(at: request.occurredAt) { input in
            try core.tickHLC(input)
        }
        let sequence = try updated.reserveDeviceSequence()
        let commandID = try updated.reserveUuidV7()[0]
        let command = TimerCommand(
            id: "command-\(commandID.uuidString.lowercased())",
            deviceSequence: sequence,
            timerId: request.timerID,
            taskId: request.type == .start ? request.taskID : nil,
            type: request.type,
            phase: request.phase,
            plannedDurationMs: Int64(request.duration * 1_000),
            occurredAt: request.occurredAt,
            hlcWallMs: updated.hlcWallMs,
            hlcCounter: updated.hlcCounter,
            observedElapsedMs: Int64(max(0, request.elapsed) * 1_000)
        )
        updated.pendingCommands.append(command)
        updated.localCommandDates[command.id] = request.localDate
        if request.type == .start {
            updated.localTimerOwners[request.timerID] = updated.deviceId
        }
        return CommandTransition(state: updated, command: command)
    }

    func prepareFinish(
        timer: CanonicalTimer,
        completionDate: Date,
        occurredAt: Date,
        localDate: Date,
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        physicalNow: Date
    ) throws -> FinishTransition {
        guard let transition = try planFinish(
            timer: timer,
            completionDate: completionDate,
            occurredAt: occurredAt,
            localDate: localDate,
            state: state,
            replicationMode: replicationMode,
            physicalNow: physicalNow,
            automatic: false,
            autoStartsBreak: state.autoStartBreaks
        ) else {
            throw SharedCoreError.invalidResponse("manual finish was ineligible")
        }
        return transition
    }

    func planFinish(
        timer: CanonicalTimer,
        completionDate: Date,
        occurredAt: Date,
        localDate: Date,
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        physicalNow: Date,
        automatic: Bool,
        autoStartsBreak: Bool
    ) throws -> FinishTransition? {
        let requestPlan = try finishRequestPlan(
            timer: timer,
            completionDate: completionDate,
            state: state,
            replicationMode: replicationMode,
            physicalNow: physicalNow,
            automatic: automatic,
            autoStartsBreak: autoStartsBreak
        )
        guard requestPlan.commandEligible else { return nil }
        let commandTransition = try makeCommand(
            CommandRequest(
                type: .finish,
                timerID: timer.id,
                taskID: nil,
                phase: timer.phase,
                duration: timer.plannedDuration,
                elapsed: timer.elapsed(at: completionDate),
                occurredAt: occurredAt,
                localDate: localDate
            ),
            state: state
        )
        return try finishTransition(
            commandTransition,
            timer: timer,
            completionDate: completionDate,
            requestPlan: requestPlan,
            autoStartsBreak: autoStartsBreak,
            replicationMode: replicationMode,
            physicalNow: physicalNow
        )
    }

    func makeAutomaticBreak(
        phase: TimerPhase,
        state: PersistedTimerState
    ) -> AutomaticBreak {
        AutomaticBreak(
            timerID: "timer-\(UUID().uuidString.lowercased())",
            phase: phase,
            duration: TimeInterval(state.settings.durationMs(for: phase)) / 1_000
        )
    }

    func prepareCentralizedAutomaticBreak(
        _ automaticBreak: AutomaticBreak,
        after focusTimer: CanonicalTimer,
        finish: FinishTransition
    ) throws -> AutomaticBreakTransition {
        let start = try makeCommand(
            CommandRequest(
                type: .start,
                timerID: automaticBreak.timerID,
                taskID: nil,
                phase: automaticBreak.phase,
                duration: automaticBreak.duration,
                elapsed: 0,
                occurredAt: finish.occurredAt,
                localDate: finish.localDate
            ),
            state: finish.state
        )
        var updated = start.state
        updated.provisionalBreaks.append(ProvisionalBreak(
            focusTimerId: focusTimer.id,
            finishCommandId: finish.command.id,
            breakTimerId: automaticBreak.timerID,
            startCommandId: start.command.id
        ))
        return AutomaticBreakTransition(
            state: updated,
            automaticBreak: automaticBreak,
            command: start.command
        )
    }

    func prepareIrohAutomaticBreak(
        completedAt: Date,
        nextPhase: TimerPhase,
        occurredAt: Date,
        localDate: Date,
        state: PersistedTimerState
    ) throws -> AutomaticBreakTransition? {
        guard occurredAt >= completedAt else { return nil }
        let automaticBreak = makeAutomaticBreak(phase: nextPhase, state: state)
        let start = try makeCommand(
            CommandRequest(
                type: .start,
                timerID: automaticBreak.timerID,
                taskID: nil,
                phase: automaticBreak.phase,
                duration: automaticBreak.duration,
                elapsed: 0,
                occurredAt: occurredAt,
                localDate: localDate
            ),
            state: state
        )
        return AutomaticBreakTransition(
            state: start.state,
            automaticBreak: automaticBreak,
            command: start.command
        )
    }

    func completionDecision(
        for timer: CanonicalTimer,
        at date: Date,
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        physicalNow: Date,
        autoStartsBreak: Bool
    ) throws -> CompletionDecision? {
        let output = try project(
            state,
            now: date,
            replicationMode: replicationMode,
            physicalNow: physicalNow
        )
        let reference = output.canonicalTimer?.anchorAt ?? date
        let bounds = try completionDayBounds(for: reference)
        let plan = try loadCore().completionPlan(.expiry(.init(
            beforeTimer: try state.physicalCanonicalTimer(timer),
            projectedTimer: output.canonicalTimer,
            history: output.history,
            selectedPhase: state.settings.selectedPhase,
            autoStartBreaks: autoStartsBreak,
            localDeviceId: state.deviceId,
            ownership: completionOwnership(for: timer, state: state),
            dayStart: bounds.start,
            dayEnd: bounds.end
        )))
        guard plan.expired, let completed = output.canonicalTimer else { return nil }
        return CompletionDecision(
            completedAt: completed.anchorAt,
            selectedPhase: plan.selectedPhase,
            generatedBreakPhase: plan.generatedBreakPhase
        )
    }
}

extension TimerSessionController {
    func project(
        _ state: PersistedTimerState,
        base override: CoreProjectionBase? = nil,
        now projectionDate: Date? = nil,
        replicationMode: ReplicationMode,
        physicalNow: Date
    ) throws -> CoreProjectionOutput {
        let core = try loadCore()
        let base = try projectionBase(for: state, override: override)
        let projectedCommands = state.localProjection(of: state.pendingCommands)
        let pending = projectionPending(for: state, commands: projectedCommands)
        let replayDate = projectionReplayDate(
            explicitDate: projectionDate,
            base: base,
            pending: pending,
            replicationMode: replicationMode,
            physicalNow: physicalNow
        )
        let output = try core.applyProjection(CoreProjectionInput(
            base: base,
            pending: pending,
            now: replayDate
        ))
        return restoreTerminalCanonicalTimer(
            in: output,
            from: state,
            projectedCommands: projectedCommands
        )
    }

    func alarmPlan(for action: AlarmAction) -> AlarmPlan {
        AlarmPlan(actions: [action])
    }

    func automaticBreakAlarmPlan(
        _ automaticBreak: AutomaticBreak,
        replacing timerID: String,
        cancelsPreviousAlarm: Bool
    ) -> AlarmPlan {
        var actions: [AlarmAction] = []
        if cancelsPreviousAlarm { actions.append(.cancel(timerID: timerID)) }
        actions.append(.schedule(
            timerID: automaticBreak.timerID,
            phase: automaticBreak.phase,
            duration: automaticBreak.duration
        ))
        return AlarmPlan(actions: actions)
    }

    func alarmPlan(
        from previousTimer: CanonicalTimer?,
        to currentTimer: CanonicalTimer?,
        at date: Date,
        ownsCurrentTimer: Bool
    ) -> AlarmPlan {
        guard let previousTimer else {
            guard let currentTimer,
                  currentTimer.status == .running,
                  ownsCurrentTimer else { return .none }
            return AlarmPlan(actions: [.schedule(
                timerID: currentTimer.id,
                phase: currentTimer.phase,
                duration: max(1, currentTimer.remaining(at: date))
            )])
        }
        guard previousTimer.status == .running || previousTimer.status == .paused else {
            return .none
        }
        guard let currentTimer,
              currentTimer.id == previousTimer.id,
              currentTimer.status == .running || currentTimer.status == .paused else {
            var actions: [AlarmAction] = [.cancel(timerID: previousTimer.id)]
            if let currentTimer,
               currentTimer.status == .running,
               ownsCurrentTimer {
                actions.append(.schedule(
                    timerID: currentTimer.id,
                    phase: currentTimer.phase,
                    duration: max(1, currentTimer.remaining(at: date))
                ))
            }
            return AlarmPlan(actions: actions)
        }
        guard currentTimer.status != previousTimer.status
                || currentTimer.phase != previousTimer.phase
                || currentTimer.plannedDurationMs != previousTimer.plannedDurationMs
                || currentTimer.elapsedAtAnchorMs != previousTimer.elapsedAtAnchorMs
                || currentTimer.anchorAt != previousTimer.anchorAt else { return .none }
        var actions: [AlarmAction] = [.cancel(timerID: previousTimer.id)]
        if currentTimer.status == .running {
            actions.append(.schedule(
                timerID: currentTimer.id,
                phase: currentTimer.phase,
                duration: max(1, currentTimer.remaining(at: date))
            ))
        }
        return AlarmPlan(actions: actions)
    }
}

extension TimerSessionController {
    static func nextPhaseGeneration(after generation: Int64) -> Int64 {
        generation == .max ? 0 : generation + 1
    }

    static func derivedNextPhase(
        from history: [HistoryItem],
        on referenceDate: Date,
        calendar: Calendar = .current
    ) -> TimerPhase? {
        guard let latestCompletion = history
            .filter({ $0.status == CanonicalTimer.Status.completed.rawValue })
            .max(by: {
                let lhsDate = $0.completedAt ?? $0.endedAt ?? .distantPast
                let rhsDate = $1.completedAt ?? $1.endedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return $0.timerId < $1.timerId
            }) else { return nil }
        guard let completionDate = latestCompletion.completedAt ?? latestCompletion.endedAt,
              calendar.isDate(completionDate, inSameDayAs: referenceDate) else { return nil }
        guard let core = try? SharedCore.bundled() else { return nil }
        return try? selectedPhase(
            after: latestCompletion,
            in: history,
            at: completionDate,
            calendar: calendar,
            core: core
        )
    }

    static func displayCompletedFocusCount(
        in history: [HistoryItem],
        on date: Date,
        calendar: Calendar = .current
    ) -> Int {
        history.count {
            $0.status == CanonicalTimer.Status.completed.rawValue
                && $0.phase == .focus
                && ($0.completedAt ?? $0.endedAt).map {
                    calendar.isDate($0, inSameDayAs: date)
                } == true
        }
    }

    static func phaseAfterFocus(
        history: [HistoryItem],
        on referenceDate: Date,
        calendar: Calendar = .current,
        core: SharedCore
    ) throws -> TimerPhase {
        let source = HistoryItem(
            id: "completion-display",
            timerId: "timer-completion-display",
            commandId: "command-completion-display",
            taskId: nil,
            phase: .focus,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: 60_000,
            completedAt: referenceDate,
            endedAt: referenceDate
        )
        return try selectedPhase(
            after: source,
            in: history,
            at: referenceDate,
            calendar: calendar,
            core: core
        )
    }

    private static func selectedPhase(
        after source: HistoryItem,
        in history: [HistoryItem],
        at date: Date,
        calendar: Calendar,
        core: SharedCore
    ) throws -> TimerPhase {
        guard let bounds = calendar.dateInterval(of: .day, for: date) else {
            throw SharedCoreError.invalidInput("completion date has no calendar day")
        }
        let output = try core.completionPlan(.finishApplied(.init(
            source: .init(
                commandId: source.commandId ?? "completion-\(source.timerId)",
                timerId: source.timerId,
                phase: source.phase,
                occurredAt: source.date ?? date
            ),
            history: history,
            autoStartBreaks: false,
            localDeviceId: "completion-policy-facade",
            ownership: nil,
            dayStart: bounds.start,
            dayEnd: bounds.end
        )))
        guard let phase = output.selectedPhase else {
            throw SharedCoreError.invalidResponse("completion phase is missing")
        }
        return phase
    }
}

private extension TimerSessionController {
    private func finishRequestPlan(
        timer: CanonicalTimer,
        completionDate: Date,
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        physicalNow: Date,
        automatic: Bool,
        autoStartsBreak: Bool
    ) throws -> CoreCompletionPlanOutput {
        let projected = try project(
            state,
            now: completionDate,
            replicationMode: replicationMode,
            physicalNow: physicalNow
        )
        return try loadCore().completionPlan(.commandRequest(.init(
            commandType: .finish,
            requestedTimer: try state.physicalCanonicalTimer(timer),
            projectedTimer: projected.canonicalTimer,
            automatic: automatic,
            generateAutoBreak: true,
            autoStartBreaks: autoStartsBreak,
            localDeviceId: state.deviceId,
            ownership: completionOwnership(for: timer, state: state)
        )))
    }

    private func finishTransition(
        _ commandTransition: CommandTransition,
        timer: CanonicalTimer,
        completionDate: Date,
        requestPlan: CoreCompletionPlanOutput,
        autoStartsBreak: Bool,
        replicationMode: ReplicationMode,
        physicalNow: Date
    ) throws -> FinishTransition {
        var updated = commandTransition.state
        let projected = try project(
            updated,
            now: completionDate,
            replicationMode: replicationMode,
            physicalNow: physicalNow
        )
        let completion = try finishAppliedPlan(
            timer: timer,
            command: commandTransition.command,
            projection: projected,
            state: updated,
            completionDate: completionDate,
            autoStartsBreak: autoStartsBreak
        )
        guard completion.queueAutoBreak == requestPlan.reserveGeneratedBreak,
              let nextPhase = completion.selectedPhase else {
            throw SharedCoreError.invalidResponse("Shared Core completion plans contradict")
        }
        recordPhaseAdvance(
            to: nextPhase,
            afterFinishing: timer,
            commandID: commandTransition.command.id,
            replicationMode: replicationMode,
            in: &updated
        )
        return FinishTransition(
            state: updated,
            command: commandTransition.command,
            nextPhase: nextPhase,
            queueAutoBreak: completion.queueAutoBreak,
            occurredAt: commandTransition.command.occurredAt,
            localDate: updated.localCommandDates[commandTransition.command.id] ?? completionDate
        )
    }

    private func finishAppliedPlan(
        timer: CanonicalTimer,
        command: TimerCommand,
        projection: CoreProjectionOutput,
        state: PersistedTimerState,
        completionDate: Date,
        autoStartsBreak: Bool
    ) throws -> CoreCompletionPlanOutput {
        let sourceDate = projection.history.first {
            $0.timerId == timer.id && $0.commandId == command.id
        }.flatMap(\.date) ?? completionDate
        let bounds = try completionDayBounds(for: sourceDate)
        return try loadCore().completionPlan(.finishApplied(.init(
            source: .init(
                commandId: command.id,
                timerId: timer.id,
                phase: timer.phase,
                occurredAt: sourceDate
            ),
            history: projection.history,
            autoStartBreaks: autoStartsBreak,
            localDeviceId: state.deviceId,
            ownership: completionOwnership(for: timer, state: state),
            dayStart: bounds.start,
            dayEnd: bounds.end
        )))
    }

    private func completionOwnership(
        for timer: CanonicalTimer,
        state: PersistedTimerState
    ) -> CoreCompletionOwnership? {
        guard let owner = state.localTimerOwners[timer.id] ?? timer.startedByDeviceId else {
            return nil
        }
        return CoreCompletionOwnership(timerId: timer.id, ownerDeviceId: owner)
    }

    private func completionDayBounds(for date: Date) throws -> DateInterval {
        guard let bounds = Calendar.current.dateInterval(of: .day, for: date) else {
            throw SharedCoreError.invalidInput("completion date has no calendar day")
        }
        return bounds
    }

    private func recordPhaseAdvance(
        to nextPhase: TimerPhase,
        afterFinishing timer: CanonicalTimer,
        commandID: String,
        replicationMode: ReplicationMode,
        in state: inout PersistedTimerState
    ) {
        let previousPhase = state.settings.selectedPhase
        guard !state.hasExplicitPhaseSelection else { return }
        state.selectedPhaseGeneration = state.selectedPhaseGeneration == .max
            ? 0
            : state.selectedPhaseGeneration + 1
        state.settings.selectedPhase = nextPhase
        guard replicationMode == .centralized else { return }
        state.provisionalPhaseAdvances.append(ProvisionalPhaseAdvance(
            sourceTimerId: timer.id,
            finishCommandId: commandID,
            previousPhase: previousPhase,
            advancedPhase: nextPhase,
            generation: state.selectedPhaseGeneration
        ))
    }

    private func loadCore() throws -> SharedCore {
        if let sharedCore { return sharedCore }
        let core = try sharedCoreProvider()
        sharedCore = core
        return core
    }

    private func projectionBase(
        for state: PersistedTimerState,
        override: CoreProjectionBase?
    ) throws -> CoreProjectionBase {
        if let override { return override }
        return CoreProjectionBase(
            canonicalTimer: try state.physicalCanonicalTimer(state.canonicalTimer),
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.selectedTaskID?.uuidString.lowercased()
        )
    }

    private func projectionPending(
        for state: PersistedTimerState,
        commands: [TimerCommand]
    ) -> CoreProjectionPending {
        CoreProjectionPending(
            commands: commands.map { CoreTimerCommand($0, deviceId: state.deviceId) },
            taskOperations: state.pendingTaskOperations.map {
                CoreTaskOperation($0, deviceId: state.deviceId)
            },
            durationOperations: state.pendingDurationOperations.map {
                CoreDurationOperation($0, deviceId: state.deviceId)
            },
            autoStartOperations: state.pendingAutoStartOperations.map(CoreAutoStartOperation.init),
            selectedTaskOperations: state.pendingSelectedTaskOperations.map(CoreSelectedTaskOperation.init)
        )
    }

    private func projectionReplayDate(
        explicitDate: Date?,
        base: CoreProjectionBase,
        pending: CoreProjectionPending,
        replicationMode: ReplicationMode,
        physicalNow: Date
    ) -> Date {
        if let explicitDate { return explicitDate }
        if replicationMode == .iroh { return physicalNow }
        let lastCommand = pending.commands.max { lhs, rhs in
            if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
            if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
            if lhs.deviceId != rhs.deviceId {
                return lhs.deviceId.utf8.lexicographicallyPrecedes(rhs.deviceId.utf8)
            }
            return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
        }
        return lastCommand?.occurredAt
            ?? base.canonicalTimer?.anchorAt
            ?? Date(timeIntervalSince1970: 0)
    }

    private func restoreTerminalCanonicalTimer(
        in output: CoreProjectionOutput,
        from state: PersistedTimerState,
        projectedCommands: [TimerCommand]
    ) -> CoreProjectionOutput {
        guard output.canonicalTimer == nil else { return output }
        guard let terminal = terminalCanonicalTimer(
            in: output,
            from: state,
            projectedCommands: projectedCommands
        ) else { return output }
        return CoreProjectionOutput(
            canonicalTimer: terminal,
            history: output.history,
            tasks: output.tasks,
            durationsMs: output.durationsMs,
            autoStartBreaks: output.autoStartBreaks,
            selectedTaskId: output.selectedTaskId,
            timerOutcomes: output.timerOutcomes,
            winningOperationIds: output.winningOperationIds
        )
    }

    private func terminalCanonicalTimer(
        in output: CoreProjectionOutput,
        from state: PersistedTimerState,
        projectedCommands: [TimerCommand]
    ) -> CanonicalTimer? {
        let historyTimerIDs = Set(output.history.map(\.timerId))
        let prior = (try? state.physicalCanonicalTimer(state.canonicalTimer))
            ?? state.canonicalTimer
        if let prior,
           prior.status != .running,
           prior.status != .paused,
           historyTimerIDs.contains(prior.id),
           projectedCommands.last(where: { $0.timerId == prior.id })?.type != .clear {
            return prior
        }
        guard let command = projectedCommands.reversed().first(where: { candidate in
            (candidate.type == .finish || candidate.type == .cancel)
                && historyTimerIDs.contains(candidate.timerId)
                && output.timerOutcomes[candidate.id]?.outcome == .applied
                && projectedCommands.last(where: {
                    $0.timerId == candidate.timerId
                })?.type != .clear
        }) else { return nil }
        return terminalTimer(from: command, prior: prior, deviceID: state.deviceId)
    }

    private func terminalTimer(
        from command: TimerCommand,
        prior: CanonicalTimer?,
        deviceID: String
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: command.timerId,
            taskId: command.taskId,
            phase: command.phase,
            status: command.type == .finish ? .completed : .cancelled,
            plannedDurationMs: command.plannedDurationMs,
            elapsedAtAnchorMs: command.type == .finish
                ? command.plannedDurationMs
                : min(command.plannedDurationMs, max(0, command.observedElapsedMs)),
            anchorAt: command.occurredAt,
            startedByDeviceId: prior?.startedByDeviceId,
            lastIntent: TimerIntent(
                type: command.type,
                commandId: command.id,
                occurredAt: command.occurredAt,
                deviceId: deviceID
            )
        )
    }
}
