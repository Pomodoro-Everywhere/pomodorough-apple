import Foundation

extension WorkspaceIntentAdmission {
    func intentWorkspace(
        state: PersistedTimerState,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) -> WorkspaceIntentWorkspace {
        let base = WorkspaceIntentBase(
            canonicalTimer: state.canonicalTimer,
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.canonicalDurations(),
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: materializedSelection(state: state)
        )
        let local = WorkspaceIntentLocal(
            commands: state.pendingCommands.map { CoreTimerCommand($0, deviceId: state.deviceId) },
            taskOperations: state.pendingTaskOperations.map { CoreTaskOperation($0, deviceId: state.deviceId) },
            durationOperations: state.pendingDurationOperations.map { CoreDurationOperation($0, deviceId: state.deviceId) },
            autoStartOperations: state.pendingAutoStartOperations.map(CoreAutoStartOperation.init),
            selectedTaskOperations: state.pendingSelectedTaskOperations.map(CoreSelectedTaskOperation.init)
        )
        let neverSent = WorkspaceIntentNeverSent(
            commands: Array(state.neverSentCommandIDs),
            taskOperations: Array(state.neverSentTaskOperationIDs),
            durationOperations: Array(state.neverSentDurationOperationIDs),
            autoStartOperations: Array(state.neverSentAutoStartOperationIDs),
            selectedTaskOperations: Array(state.neverSentSelectedTaskOperationIDs)
        )
        let head: WorkspaceIntentHead?
        if let wall = state.canonicalHeadWallMs, let counter = state.canonicalHeadCounter {
            head = WorkspaceIntentHead(wallMs: wall, counter: counter)
        } else {
            head = nil
        }
        return WorkspaceIntentWorkspace(
            base: base,
            local: local,
            canonicalHead: head,
            neverSent: neverSent,
            timerDependencies: state.pendingTimerDependencies
        )
    }

    func materializedSelection(state: PersistedTimerState) -> String? {
        guard let selected = state.selectedTaskID,
              state.tasks.contains(where: { $0.id == selected }) else { return nil }
        return selected.uuidString.lowercased()
    }

    func intentOwnership(
        kind: WorkspaceIntentKind,
        state: PersistedTimerState
    ) -> WorkspaceIntentOwnership? {
        switch kind {
        case .start, .pause, .resume, .cancel, .cancelAndClear, .clear, .selectPhase:
            return nil
        default:
            let id = state.cachedUser?.id
            return WorkspaceIntentOwnership(expectedOwnerId: id, ownerId: id)
        }
    }

    func intentDurability(
        kind: WorkspaceIntentKind,
        state: PersistedTimerState
    ) -> WorkspaceIntentDurability? {
        switch kind {
        case .start, .pause, .resume, .cancel, .cancelAndClear, .clear, .selectPhase:
            return nil
        default:
            let outgoing = state.pendingDurationOperations
                .filter { !state.neverSentDurationOperationIDs.contains($0.id) }
                .map(\.id)
            return WorkspaceIntentDurability(outgoingDurationOperationIds: outgoing, localTabId: nil)
        }
    }

    func intentLocalDurations(
        kind: WorkspaceIntentKind,
        state: PersistedTimerState
    ) -> DurationValues? {
        if case .setDuration = kind {
            return state.settings.durationsMs
        }
        return nil
    }

    func intentIdentities(
        kind: WorkspaceIntentKind,
        state: PersistedTimerState,
        occurredAt: Date
    ) throws -> WorkspaceIntentIdentities {
        var probe = state
        let core = try sharedCoreProvider()
        try probe.advanceClock(at: occurredAt) { input in
            try core.tickHLC(input)
        }
        let count = identityCount(kind: kind)
        let uuids = try probe.reserveUuidV7(count: count).map { $0.uuidString.lowercased() }
        let timerUuid: String?
        if needsTimerUuid(kind: kind) {
            timerUuid = UUID().uuidString.lowercased()
        } else {
            timerUuid = nil
        }
        return WorkspaceIntentIdentities(commandUuids: uuids, timerUuid: timerUuid)
    }

    func identityCount(kind: WorkspaceIntentKind) -> Int {
        switch kind {
        case .start, .pause, .resume, .cancel, .cancelAndClear, .clear, .selectPhase:
            return 2
        case .upsertTask, .deleteTask, .selectTask, .setDuration, .setAutoStart:
            return 3
        }
    }

    func needsTimerUuid(kind: WorkspaceIntentKind) -> Bool {
        if case .start = kind { return true }
        return false
    }
}
