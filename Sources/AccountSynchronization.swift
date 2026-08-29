import Foundation

@MainActor
final class AccountSynchronization {
    struct SyncBatch: Sendable {
        let commands: [TimerCommand]
        let taskOperations: [TaskOperation]
        let durationOperations: [DurationOperation]
        let autoStartOperations: [AutoStartOperation]
        let selectedTaskOperations: [SelectedTaskOperation]

        var isEmpty: Bool {
            commands.isEmpty
                && taskOperations.isEmpty
                && durationOperations.isEmpty
                && autoStartOperations.isEmpty
                && selectedTaskOperations.isEmpty
        }
    }

    struct SyncPlan: Sendable {
        let batch: SyncBatch
        let request: SyncRequest
    }

    struct SyncTransition: Sendable {
        var state: PersistedTimerState
        let conflictMessage: String?
    }

    struct BootstrapPreflightTransition: Sendable {
        var state: PersistedTimerState
        let response: BootstrapResponse
        let plan: CoreBootstrapPlanOutput
    }

    struct BootstrapResolutionTransition: Sendable {
        var state: PersistedTimerState
    }

    private let api: APIClient
    private let sharedCoreProvider: @MainActor () throws -> SharedCore
    private var sharedCore: SharedCore?

    init(
        api: APIClient,
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore
    ) {
        self.api = api
        self.sharedCoreProvider = sharedCoreProvider
    }

    func makeSyncPlan(state: PersistedTimerState) -> SyncPlan {
        let batch = SyncBatch(
            commands: uploadableCommands(in: state, limit: 256),
            taskOperations: Array(state.pendingTaskOperations.prefix(256)),
            durationOperations: Array(state.pendingDurationOperations.prefix(256)),
            autoStartOperations: Array(state.pendingAutoStartOperations.prefix(256)),
            selectedTaskOperations: Array(state.pendingSelectedTaskOperations.prefix(256))
        )
        return SyncPlan(
            batch: batch,
            request: SyncRequest(
                deviceId: state.deviceId,
                lastRevision: state.revision,
                commands: batch.commands,
                taskOperations: batch.taskOperations,
                durationOperations: batch.durationOperations,
                autoStartOperations: batch.autoStartOperations,
                selectedTaskOperations: batch.selectedTaskOperations
            )
        )
    }

    func sendSync(_ plan: SyncPlan) async throws -> TimedHTTPResponse<SyncResponse> {
        try await api.sync(plan.request)
    }

    func reconcileSync(
        _ sampledResponse: TimedHTTPResponse<SyncResponse>,
        plan: SyncPlan,
        state: PersistedTimerState
    ) throws -> SyncTransition {
        let response = sampledResponse.value
        guard response.hasValidCanonicalSnapshot,
              WireBounds.containsUnsigned(response.revision),
              response.revision >= state.revision else {
            throw AppError.invalidResponse
        }
        var updated = state
        try updated.mergeClock(
            serverWallMs: response.serverHlcWallMs,
            serverCounter: response.serverHlcCounter,
            serverTime: response.serverTime,
            requestWall: sampledResponse.requestWall,
            requestUptime: sampledResponse.requestUptime,
            responseUptime: sampledResponse.responseUptime
        )
        let canonicalResponse = CoreReconcileCanonicalResponse(response)
        let reconciliation = try reconcileWithCore(
            state: updated,
            sent: plan.batch,
            response: canonicalResponse
        )
        try applyCoreReconciliation(reconciliation, response: canonicalResponse, to: &updated)
        // Core represents terminal timers in history only. Retain server duplicate
        // terminal object strictly as Apple presentation state.
        updated.canonicalTimer = response.canonicalTimer
        resolveProvisionalPhaseAdvances(
            in: &updated,
            acknowledgements: response.acknowledgements,
            canonicalHistory: response.history,
            canonicalTimer: response.canonicalTimer
        )
        updateLocalTimerOwnership(
            in: &updated,
            sentCommands: plan.batch.commands,
            acknowledgements: response.acknowledgements,
            canonicalTimer: response.canonicalTimer,
            canonicalHistory: response.history
        )
        mergeSyncedSnapshot(response, into: &updated)
        return SyncTransition(
            state: updated,
            conflictMessage: conflictMessage(for: response)
        )
    }
}

extension AccountSynchronization {
    func sendBootstrapPreflight(
        state: PersistedTimerState
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        try await api.bootstrap(SyncRequest(
            deviceId: state.deviceId,
            lastRevision: state.revision,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: [],
            selectedTaskOperations: []
        ))
    }

    func reconcileBootstrapPreflight(
        _ sampledResponse: TimedHTTPResponse<BootstrapResponse>,
        state: PersistedTimerState,
        localHistory: [HistoryItem],
        hasLocalState: Bool
    ) throws -> BootstrapPreflightTransition {
        let response = sampledResponse.value
        guard response.hasValidCanonicalSnapshot,
              WireBounds.containsUnsigned(response.revision) else {
            throw AppError.invalidResponse
        }
        var updated = state
        try updated.mergeClock(
            serverWallMs: response.serverHlcWallMs,
            serverCounter: response.serverHlcCounter,
            serverTime: response.serverTime,
            requestWall: sampledResponse.requestWall,
            requestUptime: sampledResponse.requestUptime,
            responseUptime: sampledResponse.responseUptime
        )
        let plan = try loadCore().planBootstrap(CoreBootstrapPlanInput(
            localOwnerId: state.cachedUser?.id,
            currentUserId: state.bootstrapUser?.id,
            localHistory: localHistory,
            remoteHistory: response.history,
            hasLocalState: hasLocalState,
            hasRemoteState: Self.hasRemoteBootstrapState(response)
        ))
        return BootstrapPreflightTransition(state: updated, response: response, plan: plan)
    }

    func makeBootstrapResolutionRequest(
        strategy: BootstrapResolutionStrategy,
        snapshot: BootstrapResponse,
        state: PersistedTimerState
    ) -> BootstrapResolveRequest {
        let includesLocalOperations = strategy != .keepRemote
        return BootstrapResolveRequest(
            requestId: "bootstrap-resolution-\(UUID().uuidString.lowercased())",
            deviceId: state.deviceId,
            expectedRevision: snapshot.revision,
            strategy: strategy,
            commands: includesLocalOperations ? uploadableCommands(in: state) : [],
            taskOperations: includesLocalOperations ? state.pendingTaskOperations : [],
            durationOperations: includesLocalOperations ? state.pendingDurationOperations : [],
            autoStartOperations: includesLocalOperations
                ? Array(state.pendingAutoStartOperations.prefix(4_096))
                : [],
            selectedTaskOperations: includesLocalOperations
                ? Array(state.pendingSelectedTaskOperations.prefix(4_096))
                : []
        )
    }

    func validateBootstrapRequest(
        _ request: BootstrapResolveRequest,
        deviceID: String
    ) throws {
        guard request.deviceId == deviceID,
              request.commands.allSatisfy(\.isValid),
              request.taskOperations.allSatisfy(\.isValid),
              request.durationOperations.allSatisfy(\.isValid),
              (request.autoStartOperations ?? []).allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }),
              (request.selectedTaskOperations ?? []).allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }) else {
            throw AppError.invalidResponse
        }
    }

    func sendBootstrapResolution(
        _ request: BootstrapResolveRequest
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        try await api.resolveBootstrap(request)
    }

    func reconcileBootstrapResolution(
        _ sampledResponse: TimedHTTPResponse<BootstrapResponse>,
        request: BootstrapResolveRequest,
        state: PersistedTimerState,
        user: User
    ) throws -> BootstrapResolutionTransition {
        let response = sampledResponse.value
        let sent = try validatedBootstrapResolutionBatch(
            response: response,
            request: request,
            state: state
        )
        let reconciled = try reconcileCapturedBootstrapRequest(
            sampledResponse,
            request: request,
            sent: sent,
            state: state
        )
        return assembleBootstrapResolutionTransition(
            from: reconciled,
            response: response,
            request: request,
            user: user
        )
    }
}

private extension AccountSynchronization {
    private func validatedBootstrapResolutionBatch(
        response: BootstrapResponse,
        request: BootstrapResolveRequest,
        state: PersistedTimerState
    ) throws -> SyncBatch {
        let autoStartOperations = request.autoStartOperations ?? []
        let selectedTaskOperations = request.selectedTaskOperations ?? []
        guard response.hasValidCanonicalSnapshot,
              WireBounds.containsUnsigned(response.revision),
              response.revision >= request.expectedRevision,
              request.deviceId == state.deviceId,
              request.commands.allSatisfy(\.isValid),
              request.taskOperations.allSatisfy(\.isValid),
              request.durationOperations.allSatisfy(\.isValid),
              autoStartOperations.count <= 4_096,
              autoStartOperations.allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }),
              selectedTaskOperations.count <= 4_096,
              selectedTaskOperations.allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }) else {
            throw AppError.invalidResponse
        }
        return SyncBatch(
            commands: request.commands,
            taskOperations: request.taskOperations,
            durationOperations: request.durationOperations,
            autoStartOperations: autoStartOperations,
            selectedTaskOperations: selectedTaskOperations
        )
    }

    private func reconcileCapturedBootstrapRequest(
        _ sampledResponse: TimedHTTPResponse<BootstrapResponse>,
        request: BootstrapResolveRequest,
        sent: SyncBatch,
        state: PersistedTimerState
    ) throws -> PersistedTimerState {
        let response = sampledResponse.value
        var resolved = state
        if request.strategy == .keepRemote {
            clearLocalBootstrapState(in: &resolved, response: response, request: request)
        }
        try resolved.mergeClock(
            serverWallMs: response.serverHlcWallMs,
            serverCounter: response.serverHlcCounter,
            serverTime: response.serverTime,
            requestWall: sampledResponse.requestWall,
            requestUptime: sampledResponse.requestUptime,
            responseUptime: sampledResponse.responseUptime
        )
        let canonicalResponse = CoreReconcileCanonicalResponse(response)
        let reconciliation = try reconcileWithCore(
            state: resolved,
            sent: sent,
            response: canonicalResponse
        )
        try applyCoreReconciliation(reconciliation, response: canonicalResponse, to: &resolved)
        return resolved
    }

    private func assembleBootstrapResolutionTransition(
        from reconciledState: PersistedTimerState,
        response: BootstrapResponse,
        request: BootstrapResolveRequest,
        user: User
    ) -> BootstrapResolutionTransition {
        var resolved = reconciledState
        if request.strategy != .keepRemote {
            resolveProvisionalPhaseAdvances(
                in: &resolved,
                acknowledgements: response.acknowledgements,
                canonicalHistory: response.history,
                canonicalTimer: response.canonicalTimer
            )
            updateLocalTimerOwnership(
                in: &resolved,
                sentCommands: request.commands,
                acknowledgements: response.acknowledgements,
                canonicalTimer: response.canonicalTimer,
                canonicalHistory: response.history
            )
            resolved.mergeKnownTasks(response.tasks)
        }
        resolved.cachedUser = user
        resolved.bootstrapUser = nil
        resolved.pendingBootstrapResolution = nil
        resolved.migrateLegacyTimerOwnership()
        resolved.pruneLocalCommandDates()
        return BootstrapResolutionTransition(state: resolved)
    }

    private func uploadableCommands(
        in state: PersistedTimerState,
        limit: Int? = nil
    ) -> [TimerCommand] {
        let provisionalTimerIDs = Set(state.provisionalBreaks.map(\.breakTimerId))
        let commands = state.pendingCommands.prefix {
            !provisionalTimerIDs.contains($0.timerId)
        }
        guard let limit else { return Array(commands) }
        return Array(commands.prefix(limit))
    }

    private func reconcileWithCore(
        state: PersistedTimerState,
        sent: SyncBatch,
        response: CoreReconcileCanonicalResponse
    ) throws -> CoreReconcileOutput {
        try loadCore().reconcileRebase(CoreReconcileInput(
            local: CoreReconcileLocalQueues(state: state),
            sent: CoreReconcileSentQueues(
                commands: sent.commands,
                taskOperations: sent.taskOperations,
                durationOperations: sent.durationOperations,
                autoStartOperations: sent.autoStartOperations,
                selectedTaskOperations: sent.selectedTaskOperations
            ),
            response: response,
            timerDependencies: coreTimerDependencies(in: state)
        ))
    }

    private func applyCoreReconciliation(
        _ output: CoreReconcileOutput,
        response: CoreReconcileCanonicalResponse,
        to state: inout PersistedTimerState
    ) throws {
        state.pendingCommands = try output.nativePendingCommands(deviceId: state.deviceId)
        state.pendingTaskOperations = try output.nativePendingTaskOperations(deviceId: state.deviceId)
        state.pendingDurationOperations = try output.nativePendingDurationOperations(deviceId: state.deviceId)
        state.pendingAutoStartOperations = try output.nativePendingAutoStartOperations(deviceId: state.deviceId)
        state.pendingSelectedTaskOperations = try output.nativePendingSelectedTaskOperations(
            deviceId: state.deviceId
        )
        state.revision = output.revision
        state.canonicalTimer = output.baseTimer
        state.history = output.baseHistory
        state.tasks = output.baseTasks
        state.settings.durationsMs = output.baseDurationsMs
        state.autoStartBreaks = output.baseAutoStartBreaks
        state.selectedTaskID = output.baseSelectedTaskId.flatMap(UUID.init(uuidString:))

        let pendingIDs = Set(state.pendingCommands.map(\.id))
        let promotedIDs = Set(output.promotedTimerOperationIds)
        let droppedIDs = Set(output.droppedTimerOperationIds)
        state.provisionalBreaks.removeAll { provisional in
            promotedIDs.contains(provisional.startCommandId)
                || droppedIDs.contains(provisional.startCommandId)
                || !pendingIDs.contains(provisional.startCommandId)
        }
        for timerID in output.droppedTimerIds {
            state.localTimerOwners.removeValue(forKey: timerID)
        }
        guard state.revision == response.revision else {
            throw SharedCoreError.invalidResponse(
                "reconciled revision changed during native adaptation"
            )
        }
    }

    private func coreTimerDependencies(
        in state: PersistedTimerState
    ) -> [CoreTimerDependency] {
        var dependencies: [CoreTimerDependency] = []
        var children: Set<String> = []
        for provisional in state.provisionalBreaks {
            guard
                let finishIndex = state.pendingCommands.firstIndex(where: {
                    $0.id == provisional.finishCommandId
                }),
                let startIndex = state.pendingCommands.firstIndex(where: {
                    $0.id == provisional.startCommandId
                }),
                finishIndex < startIndex
            else { continue }
            let sourceDate = state.pendingCommands[finishIndex].occurredAt
            guard let sourceDay = Calendar.current.dateInterval(of: .day, for: sourceDate) else {
                continue
            }
            dependencies.append(CoreTimerDependency(
                operationId: provisional.startCommandId,
                dependsOnOperationId: provisional.finishCommandId,
                generatedBreak: true,
                sourceDayStart: sourceDay.start,
                sourceDayEnd: sourceDay.end
            ))
            children.insert(provisional.startCommandId)

            var parentID = provisional.startCommandId
            for command in state.pendingCommands.suffix(from: startIndex + 1) {
                if command.type == .start { break }
                guard command.timerId == provisional.breakTimerId,
                      children.insert(command.id).inserted else { continue }
                dependencies.append(CoreTimerDependency(
                    operationId: command.id,
                    dependsOnOperationId: parentID
                ))
                parentID = command.id
            }
        }
        return dependencies
    }

    private func resolveProvisionalPhaseAdvances(
        in state: inout PersistedTimerState,
        acknowledgements: [Acknowledgement],
        canonicalHistory: [HistoryItem],
        canonicalTimer: CanonicalTimer?
    ) {
        let acknowledgementsByID = Dictionary(
            uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) }
        )
        let advances = state.provisionalPhaseAdvances
        let earliestInvalidIndex = advances.indices.first { index in
            let provisional = advances[index]
            guard let acknowledgement = acknowledgementsByID[provisional.finishCommandId] else {
                return false
            }
            return acknowledgement.outcome == .rejected
                || !hasCanonicalFinish(
                    provisional,
                    history: canonicalHistory,
                    timer: canonicalTimer
                )
        }
        var unresolvedReversed: [ProvisionalPhaseAdvance] = []
        for index in advances.indices.reversed() {
            let provisional = advances[index]
            let invalidatedByDependency = earliestInvalidIndex.map { index >= $0 } ?? false
            let acknowledgement = acknowledgementsByID[provisional.finishCommandId]
            guard invalidatedByDependency || acknowledgement != nil else {
                unresolvedReversed.append(provisional)
                continue
            }
            if invalidatedByDependency,
               state.selectedPhaseGeneration == provisional.generation,
               state.settings.selectedPhase == provisional.advancedPhase {
                state.settings.selectedPhase = provisional.previousPhase
                state.selectedPhaseGeneration = provisional.generation == 0
                    ? .max
                    : provisional.generation - 1
            }
        }
        state.provisionalPhaseAdvances = unresolvedReversed.reversed()
    }

    private func hasCanonicalFinish(
        _ provisional: ProvisionalPhaseAdvance,
        history: [HistoryItem],
        timer: CanonicalTimer?
    ) -> Bool {
        history.contains {
            $0.timerId == provisional.sourceTimerId
                && $0.commandId == provisional.finishCommandId
                && $0.status == CanonicalTimer.Status.completed.rawValue
        } || timer.map {
            $0.id == provisional.sourceTimerId
                && $0.status == .completed
                && $0.lastIntent?.type == .finish
                && $0.lastIntent?.commandId == provisional.finishCommandId
        } == true
    }

    private func updateLocalTimerOwnership(
        in state: inout PersistedTimerState,
        sentCommands: [TimerCommand],
        acknowledgements: [Acknowledgement],
        canonicalTimer: CanonicalTimer?,
        canonicalHistory: [HistoryItem]
    ) {
        let acknowledgementsByID = Dictionary(
            uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) }
        )
        for command in sentCommands where command.type == .start {
            guard let acknowledgement = acknowledgementsByID[command.id] else { continue }
            let canonicallyAccepted = canonicalTimer?.id == command.timerId
                || canonicalHistory.contains { $0.timerId == command.timerId }
            if acknowledgement.outcome == .applied || canonicallyAccepted {
                state.localTimerOwners[command.timerId] = state.deviceId
            } else {
                state.localTimerOwners.removeValue(forKey: command.timerId)
            }
        }
    }

    private func mergeSyncedSnapshot(
        _ response: SyncResponse,
        into state: inout PersistedTimerState
    ) {
        state.migrateLegacyTimerOwnership()
        state.mergeKnownTasks(response.tasks)
        let hasActiveCanonicalTimer = response.canonicalTimer.map {
            $0.status == .running || $0.status == .paused
        } ?? false
        if !hasActiveCanonicalTimer,
           state.pendingCommands.isEmpty,
           !state.hasExplicitPhaseSelection,
           let derivedPhase = TimerSessionController.derivedNextPhase(
               from: response.history,
               on: response.serverTime
           ) {
            state.settings.selectedPhase = derivedPhase
        }
        state.pruneLocalCommandDates()
    }

    private func conflictMessage(for response: SyncResponse) -> String? {
        if let conflict = response.acknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a timer action as \(conflict.outcome.rawValue).")
                : conflict.reason
        }
        if let conflict = response.taskAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a task change as \(conflict.outcome.rawValue).")
                : conflict.reason
        }
        if let conflict = response.durationAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a duration change as \(conflict.outcome.rawValue).")
                : conflict.reason
        }
        if let conflict = response.autoStartAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved an auto-start change as \(conflict.outcome.rawValue).")
                : conflict.reason
        }
        if let conflict = response.selectedTaskAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a selected-task change as \(conflict.outcome.rawValue).")
                : conflict.reason
        }
        return nil
    }

    private func clearLocalBootstrapState(
        in state: inout PersistedTimerState,
        response: BootstrapResponse,
        request: BootstrapResolveRequest
    ) {
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        if request.autoStartOperations != nil { state.pendingAutoStartOperations = [] }
        if request.selectedTaskOperations != nil { state.pendingSelectedTaskOperations = [] }
        state.localTimerOwners = [:]
        state.provisionalBreaks = []
        state.provisionalPhaseAdvances = []
        state.knownTasks = response.tasks
        state.legacyTaskAssignments = [:]
    }

    private static func hasRemoteBootstrapState(_ response: BootstrapResponse) -> Bool {
        response.canonicalTimer != nil
            || !response.history.isEmpty
            || !response.tasks.isEmpty
            || response.durationsMs != .defaults
            || response.autoStartBreaks
    }

    private func loadCore() throws -> SharedCore {
        if let sharedCore { return sharedCore }
        let core = try sharedCoreProvider()
        sharedCore = core
        return core
    }
}
