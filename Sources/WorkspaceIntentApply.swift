import Foundation

extension WorkspaceIntentAdmission {
    func applyQueues(
        workspaceLocal: WorkspaceIntentResponseLocal,
        neverSent: WorkspaceIntentResponseNeverSent,
        state: inout PersistedTimerState
    ) throws {
        let deviceId = state.deviceId
        if let commands = workspaceLocal.commands {
            state.pendingCommands = try commands.map { try $0.native(deviceId: deviceId) }
        }
        if let tasks = workspaceLocal.taskOperations {
            state.pendingTaskOperations = try tasks.map { try $0.native(deviceId: deviceId) }
        }
        if let durations = workspaceLocal.durationOperations {
            state.pendingDurationOperations = try durations.map { try $0.native(deviceId: deviceId) }
        }
        if let auto = workspaceLocal.autoStartOperations {
            state.pendingAutoStartOperations = try auto.map { try $0.native(deviceId: deviceId) }
        }
        if let selected = workspaceLocal.selectedTaskOperations {
            state.pendingSelectedTaskOperations = try selected.map { try $0.native(deviceId: deviceId) }
        }
        if let commands = neverSent.commands { state.neverSentCommandIDs = Set(commands) }
        if let tasks = neverSent.taskOperations { state.neverSentTaskOperationIDs = Set(tasks) }
        if let durations = neverSent.durationOperations { state.neverSentDurationOperationIDs = Set(durations) }
        if let auto = neverSent.autoStartOperations { state.neverSentAutoStartOperationIDs = Set(auto.map { $0.lowercased() }) }
        if let selected = neverSent.selectedTaskOperations {
            state.neverSentSelectedTaskOperationIDs = Set(selected.map { $0.lowercased() })
        }
        state.pruneNeverSentProofToPending()
    }

    func applyAllocation(allocation: WorkspaceIntentResponseAllocation, state: inout PersistedTimerState) {
        if let wall = allocation.hlc?.wallMs { state.hlcWallMs = wall }
        if let counter = allocation.hlc?.counter { state.hlcCounter = counter }
        if let sequence = allocation.deviceSequence { state.nextSequence = sequence + 1 }
        if let last = allocation.lastUuid, let uuid = UUID(uuidString: last) {
            state.lastUuidV7 = uuid
        }
    }

    func applyObservation(observation: WorkspaceIntentResponseObservation, state: inout PersistedTimerState) throws {
        guard let times = observation.commandTimes else { return }
        var mapped: [String: Date] = [:]
        for (id, date) in times {
            mapped[id] = date
        }
        state.localCommandDates = mapped
        state.pruneLocalCommandDates()
    }

    func applySelection(selection: WorkspaceIntentResponseSelection, state: inout PersistedTimerState) {
        if let phase = selection.phase { state.settings.selectedPhase = phase }
        if let generation = selection.generation, let value = Int64(generation) {
            state.selectedPhaseGeneration = value
        }
        if let explicit = selection.explicit { state.hasExplicitPhaseSelection = explicit }
    }

    func applyDependencies(workspace: WorkspaceIntentResponseWorkspace, state: inout PersistedTimerState) {
        if let dependencies = workspace.timerDependencies {
            state.pendingTimerDependencies = dependencies
        }
        if let wall = workspace.canonicalHead?.wallMs, let counter = workspace.canonicalHead?.counter {
            state.canonicalHeadWallMs = wall
            state.canonicalHeadCounter = counter
        }
    }

    func applyOwnership(response: WorkspaceIntentResponse, state: inout PersistedTimerState) {
        guard let writes = response.ownershipWrites else { return }
        for write in writes {
            if write.kind == "recordStart" || write.kind == "recordLocalStart",
               let timerId = write.timerId, let deviceId = write.deviceId {
                state.localTimerOwners[timerId] = deviceId
            }
        }
    }

    func applyOptimistic(
        kind: WorkspaceIntentKind,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot,
        state: inout PersistedTimerState
    ) {
        switch kind {
        case .upsertTask(let title):
            if let task = FocusTask(title: title) {
                state.mergeKnownTasks([task])
            }
        case .deleteTask:
            break
        case .selectTask(let taskId):
            state.selectedTaskID = taskId.flatMap(UUID.init(uuidString:))
        case .setDuration(let phase, let minutes):
            let clamped = min(180, max(1, minutes))
            state.settings.setMinutes(clamped, for: phase)
        case .setAutoStart:
            break
        default:
            break
        }
    }

    func planRequirements(response: WorkspaceIntentResponse) -> SynchronizedWorkspaceMutationController.Requirements {
        var requirements = SynchronizedWorkspaceMutationController.Requirements()
        requirements.timerCommandIDs = Set(response.atomicCommandIds ?? [])
        let ids = response.atomicOperationIds
        requirements.taskOperationIDs = Set(ids?.taskOperations ?? [])
        requirements.durationOperationIDs = Set(ids?.durationOperations ?? [])
        requirements.autoStartOperationIDs = Set((ids?.autoStartOperations ?? []).map { $0.lowercased() })
        requirements.selectedTaskOperationIDs = Set((ids?.selectedTaskOperations ?? []).map { $0.lowercased() })
        if requirements.timerCommandIDs.isEmpty, let commands = response.commands {
            requirements.timerCommandIDs = Set(commands.map(\.id))
        }
        return requirements
    }
}
