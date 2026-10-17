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
        let legacyDependencyReviewRequired: Bool
        let isSavedReplay: Bool
        let coreStatus: String
        let nextCursor: String
        let heldTimerOperationId: String?

        init(
            batch: SyncBatch,
            request: SyncRequest,
            legacyDependencyReviewRequired: Bool,
            isSavedReplay: Bool = false,
            coreStatus: String = "planned",
            nextCursor: String = "commands",
            heldTimerOperationId: String? = nil
        ) {
            self.batch = batch
            self.request = request
            self.legacyDependencyReviewRequired = legacyDependencyReviewRequired
            self.isSavedReplay = isSavedReplay
            self.coreStatus = coreStatus
            self.nextCursor = nextCursor
            self.heldTimerOperationId = heldTimerOperationId
        }
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

    /// S1 OOM relief: releases the cached WasmKit runtime (Store/Memory)
    /// after a memory warning. Next sync lazily reloads it. Safe to call
    /// mid-sync: in-flight reconciliations hold their own reference.
    func releaseCachedCoreForMemoryPressure() {
        sharedCore?.releaseRuntimeForMemoryPressure()
        sharedCore = nil
    }

    func makeSyncPlan(state: PersistedTimerState) throws -> SyncPlan {
        let reviewRequired = LegacyBreakDependencyRecovery.requiresReview(state)
        guard !reviewRequired else {
            return SyncPlan(
                batch: SyncBatch(
                    commands: [], taskOperations: [], durationOperations: [],
                    autoStartOperations: [], selectedTaskOperations: []
                ),
                request: SyncRequest(
                    deviceId: state.deviceId, lastRevision: state.revision,
                    commands: [], taskOperations: [], durationOperations: [],
                    autoStartOperations: [], selectedTaskOperations: []
                ),
                legacyDependencyReviewRequired: true
            )
        }
        if let claim = state.outgoingSyncClaim {
            return try savedSyncPlan(claim: claim, state: state)
        }
        return try newSyncPlan(state: state)
    }

    func prepareSyncPlan(state: PersistedTimerState) throws -> (plan: SyncPlan, retired: PersistedTimerState) {
        let plan = try makeSyncPlan(state: state)
        guard !plan.legacyDependencyReviewRequired else { return (plan, state) }
        guard !plan.isSavedReplay else { return (plan, state) }
        guard plan.coreStatus == "planned", !plan.batch.isEmpty else { return (plan, state) }
        var retired = state
        retired.outgoingSyncClaim = plan.request
        retired.syncBatchCursor = plan.nextCursor
        retired.retireNeverSentProof(
            commands: plan.batch.commands.map(\.id),
            taskOperations: plan.batch.taskOperations.map(\.id),
            durationOperations: plan.batch.durationOperations.map(\.id),
            autoStartOperations: plan.batch.autoStartOperations.map { $0.id.uuidString.lowercased() },
            selectedTaskOperations: plan.batch.selectedTaskOperations.map { $0.id.uuidString.lowercased() }
        )
        return (plan, retired)
    }

    func discardSavedSyncClaim(confirmed: Bool, state: PersistedTimerState) throws -> PersistedTimerState {
        guard let claim = state.outgoingSyncClaim else {
            throw SyncBatchPlanError.invalidResponse("no saved sync claim")
        }
        let planner = SyncBatchPlanner(core: try loadCore())
        let verdict = try planner.checkSavedSync(claim)
        guard verdict.status == "oversized_saved" else {
            throw SyncBatchPlanError.invalidResponse("saved claim must replay exactly")
        }
        guard confirmed else {
            throw SyncBatchPlanError.oversizedSaved
        }
        var cleared = state
        cleared.outgoingSyncClaim = nil
        return cleared
    }

    private func savedSyncPlan(claim: SyncRequest, state: PersistedTimerState) throws -> SyncPlan {
        let planner = SyncBatchPlanner(core: try loadCore())
        let verdict = try planner.checkSavedSync(claim)
        guard verdict.status == "replay_saved" else {
            throw SyncBatchPlanError.oversizedSaved
        }
        guard claim.deviceId == state.deviceId else {
            throw SyncBatchPlanError.invalidResponse("saved claim device mismatch")
        }
        return SyncPlan(
            batch: SyncBatch(
                commands: claim.commands, taskOperations: claim.taskOperations,
                durationOperations: claim.durationOperations,
                autoStartOperations: claim.autoStartOperations ?? [],
                selectedTaskOperations: claim.selectedTaskOperations
            ),
            request: claim,
            legacyDependencyReviewRequired: false,
            isSavedReplay: true,
            coreStatus: "replay_saved",
            nextCursor: state.syncBatchCursor,
            heldTimerOperationId: nil
        )
    }

    private func newSyncPlan(state: PersistedTimerState) throws -> SyncPlan {
        let planner = SyncBatchPlanner(core: try loadCore())
        let plan = try planner.planSync(
            commands: state.pendingCommands,
            tasks: state.pendingTaskOperations,
            durations: state.pendingDurationOperations,
            autoStarts: state.pendingAutoStartOperations,
            selectedTasks: state.pendingSelectedTaskOperations,
            deviceId: state.deviceId,
            dependencies: coreTimerDependencies(in: state),
            cursor: state.syncBatchCursor
        )
        guard plan.status == "planned" else {
            return SyncPlan(
                batch: SyncBatch(
                    commands: [], taskOperations: [], durationOperations: [],
                    autoStartOperations: [], selectedTaskOperations: []
                ),
                request: SyncRequest(
                    deviceId: state.deviceId, lastRevision: state.revision,
                    commands: [], taskOperations: [], durationOperations: [],
                    autoStartOperations: [], selectedTaskOperations: []
                ),
                legacyDependencyReviewRequired: false,
                isSavedReplay: false,
                coreStatus: plan.status,
                nextCursor: state.syncBatchCursor,
                heldTimerOperationId: plan.heldTimerOperationId
            )
        }
        let batch = try resolveSyncBatch(plan: plan, state: state)
        guard let next = plan.nextDomain else {
            throw SyncBatchPlanError.invalidResponse("planned plan misses cursor")
        }
        return SyncPlan(
            batch: batch,
            request: SyncRequest(
                deviceId: state.deviceId, lastRevision: state.revision,
                commands: batch.commands, taskOperations: batch.taskOperations,
                durationOperations: batch.durationOperations,
                autoStartOperations: batch.autoStartOperations,
                selectedTaskOperations: batch.selectedTaskOperations
            ),
            legacyDependencyReviewRequired: false,
            isSavedReplay: false,
            coreStatus: "planned",
            nextCursor: next,
            heldTimerOperationId: plan.heldTimerOperationId
        )
    }

    private func resolveSyncBatch(plan: CoreBatchPlan, state: PersistedTimerState) throws -> SyncBatch {
        let commands = try resolveCommands(ids: plan.selected.commands, state: state)
        let tasks = try resolveTasks(ids: plan.selected.taskOperations, state: state)
        let durations = try resolveDurations(ids: plan.selected.durationOperations, state: state)
        let autoStarts = try resolveAutoStarts(ids: plan.selected.autoStartOperations, state: state)
        let selected = try resolveSelected(ids: plan.selected.selectedTaskOperations, state: state)
        return SyncBatch(
            commands: commands, taskOperations: tasks,
            durationOperations: durations, autoStartOperations: autoStarts,
            selectedTaskOperations: selected
        )
    }

    private func resolveCommands(ids: [String], state: PersistedTimerState) throws -> [TimerCommand] {
        let index = Dictionary(uniqueKeysWithValues: state.pendingCommands.map { ($0.id, $0) })
        return try ids.map { id in
            guard let record = index[id] else {
                throw SyncBatchPlanError.invalidResponse("Core selected unknown command")
            }
            return record
        }
    }

    private func resolveTasks(ids: [String], state: PersistedTimerState) throws -> [TaskOperation] {
        let index = Dictionary(uniqueKeysWithValues: state.pendingTaskOperations.map { ($0.id, $0) })
        return try ids.map { id in
            guard let record = index[id] else {
                throw SyncBatchPlanError.invalidResponse("Core selected unknown task")
            }
            return record
        }
    }

    private func resolveDurations(ids: [String], state: PersistedTimerState) throws -> [DurationOperation] {
        let index = Dictionary(uniqueKeysWithValues: state.pendingDurationOperations.map { ($0.id, $0) })
        return try ids.map { id in
            guard let record = index[id] else {
                throw SyncBatchPlanError.invalidResponse("Core selected unknown duration")
            }
            return record
        }
    }

    private func resolveAutoStarts(ids: [String], state: PersistedTimerState) throws -> [AutoStartOperation] {
        let index = Dictionary(
            uniqueKeysWithValues: state.pendingAutoStartOperations.map {
                ($0.id.uuidString.lowercased(), $0)
            }
        )
        return try ids.map { id in
            guard let record = index[id.lowercased()] else {
                throw SyncBatchPlanError.invalidResponse("Core selected unknown auto-start")
            }
            return record
        }
    }

    private func resolveSelected(ids: [String], state: PersistedTimerState) throws -> [SelectedTaskOperation] {
        let index = Dictionary(
            uniqueKeysWithValues: state.pendingSelectedTaskOperations.map {
                ($0.id.uuidString.lowercased(), $0)
            }
        )
        return try ids.map { id in
            guard let record = index[id.lowercased()] else {
                throw SyncBatchPlanError.invalidResponse("Core selected unknown selected-task")
            }
            return record
        }
    }

    func sendSync(
        _ plan: SyncPlan, state: PersistedTimerState,
        willSend: @MainActor () -> Void = {}
    ) async throws -> TimedHTTPResponse<SyncResponse> {
        guard !plan.legacyDependencyReviewRequired else { throw LegacyTimerDependencyReview.required }
        try validateLegacyTimerSubmission(state: state)
        guard plan.coreStatus != "blocked_dependency" else { throw SyncBatchPlanError.blockedSync }
        try validateSyncRequest(plan.request, state: state)
        // From this point, actor suspension or transport failure cannot prove non-delivery.
        willSend()
        return try await api.sync(plan.request)
    }

    private func validateSyncRequest(_ request: SyncRequest, state: PersistedTimerState) throws {
        guard request.deviceId == state.deviceId,
              WireBounds.containsUnsigned(request.lastRevision),
              request.commands.allSatisfy(\.isValid),
              request.taskOperations.allSatisfy(\.isValid),
              request.durationOperations.allSatisfy(\.isValid),
              (request.autoStartOperations ?? []).allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }),
              request.selectedTaskOperations.allSatisfy({
                  $0.isValid && $0.deviceId == request.deviceId
              }) else { throw AppError.invalidResponse }
        let verdict = try SyncBatchPlanner(core: loadCore()).checkSavedSync(request)
        guard verdict.status == "replay_saved" else { throw SyncBatchPlanError.oversizedSaved }
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
        let (reconciliation, dependencies) = try reconcileWithCore(
            state: updated,
            sent: plan.batch,
            response: canonicalResponse
        )
        try applyCoreReconciliation(reconciliation, dependencies: dependencies,
                                    response: canonicalResponse, to: &updated)
        // Core represents terminal timers in history only. Retain server duplicate
        // terminal object strictly as Apple presentation state.
        updated.canonicalTimer = response.canonicalTimer
        try resolveProvisionalPhaseAdvances(
            in: &updated,
            acknowledgements: response.acknowledgements,
            canonicalHistory: response.history,
            canonicalTimer: response.canonicalTimer
        )
        try updateLocalTimerOwnership(
            in: &updated,
            sentCommands: plan.batch.commands,
            acknowledgements: response.acknowledgements,
            canonicalTimer: response.canonicalTimer,
            canonicalHistory: response.history
        )
        mergeSyncedSnapshot(response, into: &updated)
        updated.outgoingSyncClaim = nil
        return SyncTransition(state: updated, conflictMessage: conflictMessage(for: response))
    }
}

extension AccountSynchronization {
    func sendBootstrapPreflight(
        state: PersistedTimerState
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        // Bootstrap preflight is GET-only and carries no local operations.
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
    ) throws -> BootstrapResolveRequest {
        let planner = SyncBatchPlanner(core: try loadCore())
        let dependencies = coreTimerDependencies(in: state)
        let plan = try planner.planBootstrap(
            commands: state.pendingCommands,
            tasks: state.pendingTaskOperations,
            durations: state.pendingDurationOperations,
            autoStarts: state.pendingAutoStartOperations,
            selectedTasks: state.pendingSelectedTaskOperations,
            deviceId: state.deviceId,
            dependencies: dependencies,
            strategy: strategy
        )
        guard plan.status == "planned" else {
            if plan.status == "oversized" {
                throw SyncBatchPlanError.oversizedBootstrap
            }
            throw SyncBatchPlanError.blockedBootstrap
        }
        let batch = try resolveBootstrapBatch(plan: plan, state: state)
        return BootstrapResolveRequest(
            requestId: "bootstrap-resolution-\(UUID().uuidString.lowercased())",
            deviceId: state.deviceId,
            expectedRevision: snapshot.revision,
            strategy: strategy,
            commands: batch.commands,
            taskOperations: batch.taskOperations,
            durationOperations: batch.durationOperations,
            autoStartOperations: batch.autoStartOperations,
            selectedTaskOperations: batch.selectedTaskOperations
        )
    }

    private func resolveBootstrapBatch(plan: CoreBatchPlan, state: PersistedTimerState) throws -> SyncBatch {
        let commands = try resolveCommands(ids: plan.selected.commands, state: state)
        let tasks = try resolveTasks(ids: plan.selected.taskOperations, state: state)
        let durations = try resolveDurations(ids: plan.selected.durationOperations, state: state)
        let autoStarts = try resolveAutoStarts(ids: plan.selected.autoStartOperations, state: state)
        let selected = try resolveSelected(ids: plan.selected.selectedTaskOperations, state: state)
        return SyncBatch(
            commands: commands, taskOperations: tasks,
            durationOperations: durations, autoStartOperations: autoStarts,
            selectedTaskOperations: selected
        )
    }

    func retiredStateForBootstrapRequest(
        _ request: BootstrapResolveRequest,
        state: PersistedTimerState
    ) -> PersistedTimerState {
        var retired = state
        retired.retireNeverSentProof(
            commands: request.commands.map(\.id),
            taskOperations: request.taskOperations.map(\.id),
            durationOperations: request.durationOperations.map(\.id),
            autoStartOperations: (request.autoStartOperations ?? []).map { $0.id.uuidString.lowercased() },
            selectedTaskOperations: (request.selectedTaskOperations ?? []).map { $0.id.uuidString.lowercased() }
        )
        return retired
    }

    func validateBootstrapRequest(
        _ request: BootstrapResolveRequest,
        state: PersistedTimerState
    ) throws {
        try validateLegacyBootstrapSubmission(request, state: state)
        guard request.deviceId == state.deviceId,
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
        try validateSavedBootstrapClaim(request)
    }

    private func validateSavedBootstrapClaim(_ request: BootstrapResolveRequest) throws {
        let planner = SyncBatchPlanner(core: try loadCore())
        let verdict = try planner.checkSavedBootstrap(request)
        guard verdict.status == "replay_saved" else {
            throw SyncBatchPlanError.oversizedBootstrap
        }
    }

    func sendBootstrapResolution(
        _ request: BootstrapResolveRequest, state: PersistedTimerState
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        try validateBootstrapRequest(request, state: state)
        return try await api.resolveBootstrap(request)
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
        return try assembleBootstrapResolutionTransition(
            from: reconciled,
            response: response,
            request: request,
            user: user
        )
    }
}

private extension AccountSynchronization {
    private func validateLegacyTimerSubmission(state: PersistedTimerState) throws {
        if LegacyBreakDependencyRecovery.requiresReview(state) { throw LegacyTimerDependencyReview.required }
    }

    private func validateLegacyBootstrapSubmission(
        _ request: BootstrapResolveRequest, state: PersistedTimerState
    ) throws {
        // Keep-remote carries no queued timer work. A malformed saved request
        // still cannot smuggle a legacy identity through that strategy.
        if request.strategy == .keepRemote, request.commands.isEmpty { return }
        try validateLegacyTimerSubmission(state: state)
    }

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
        let (reconciliation, dependencies) = try reconcileWithCore(
            state: resolved,
            sent: sent,
            response: canonicalResponse
        )
        try applyCoreReconciliation(reconciliation, dependencies: dependencies,
                                    response: canonicalResponse, to: &resolved)
        return resolved
    }

    private func assembleBootstrapResolutionTransition(
        from reconciledState: PersistedTimerState,
        response: BootstrapResponse,
        request: BootstrapResolveRequest,
        user: User
    ) throws -> BootstrapResolutionTransition {
        var resolved = reconciledState
        if request.strategy != .keepRemote {
            try resolveProvisionalPhaseAdvances(
                in: &resolved,
                acknowledgements: response.acknowledgements,
                canonicalHistory: response.history,
                canonicalTimer: response.canonicalTimer
            )
            try updateLocalTimerOwnership(
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
        resolved.outgoingSyncClaim = nil
        resolved.migrateLegacyTimerOwnership()
        resolved.pruneLocalCommandDates()
        return BootstrapResolutionTransition(state: resolved)
    }

    private func reconcileWithCore(
        state: PersistedTimerState,
        sent: SyncBatch,
        response: CoreReconcileCanonicalResponse
    ) throws -> (CoreReconcileOutput, [CoreTimerDependency]) {
        let dependencies = coreTimerDependencies(in: state)
        let output = try loadCore().reconcileRebase(CoreReconcileInput(
            local: CoreReconcileLocalQueues(state: state),
            sent: CoreReconcileSentQueues(
                commands: sent.commands,
                taskOperations: sent.taskOperations,
                durationOperations: sent.durationOperations,
                autoStartOperations: sent.autoStartOperations,
                selectedTaskOperations: sent.selectedTaskOperations
            ),
            response: response,
            timerDependencies: dependencies,
            neverSent: state.neverSentProof()
        ))
        return (output, dependencies)
    }

    private func applyCoreReconciliation(
        _ output: CoreReconcileOutput,
        dependencies: [CoreTimerDependency],
        response: CoreReconcileCanonicalResponse,
        to state: inout PersistedTimerState
    ) throws {
        state.pendingCommands = try output.nativePendingCommands(deviceId: state.deviceId)
        state.pendingTimerDependencies = retainedTimerDependencies(dependencies, output: output)
        state.pruneLegacyUnresolvedCommandsToPending()
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
        state.installCanonicalDurations(output.baseDurationsMs)
        state.settings.durationsMs = output.baseDurationsMs
        state.autoStartBreaks = output.baseAutoStartBreaks
        state.selectedTaskID = output.baseSelectedTaskId.flatMap(UUID.init(uuidString:))
        state.canonicalSelectedTask = CanonicalSelectedTask(taskID: state.selectedTaskID)
        state.storeCanonicalHead(wallMs: response.serverHlcWallMs, counter: response.serverHlcCounter)
        state.pruneNeverSentProofToPending()
        // Core v2 projectionPending is the authoritative safe subset used for
        // output.timer/history. Local safeProjection* mirrors Core
        // delivery::Policy::projectable (neverSent + head); cross-check so
        // silent recomputation drift fails closed instead of diverging.
        try Self.validateProjectionEquivalence(output.projectionPending, state: state)

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

    private func retainedTimerDependencies(
        _ dependencies: [CoreTimerDependency],
        output: CoreReconcileOutput
    ) -> [CoreTimerDependency] {
        let pending = Dictionary(uniqueKeysWithValues: output.pending.map { ($0.id, $0) })
        let returnedIDs = Set(output.pendingTimerDependencies.map(\.operationId))
        // Bundled Core v0.38 promotes a generated break's Finish with its Start.
        // Keep the direct edge Core received until either command leaves its
        // pending queue; Core still decides acknowledgements and drops.
        return output.pendingTimerDependencies + dependencies.filter {
            let child = pending[$0.operationId]
            let parent = pending[$0.dependsOnOperationId]
            return child?.type == .finish && parent?.type == .start
                && parent?.phase.isBreak == true && child?.timerId == parent?.timerId
                && !returnedIDs.contains($0.operationId)
        }
    }

    private static func validateProjectionEquivalence(
        _ projected: CoreReconcileProjectionPending?,
        state: PersistedTimerState
    ) throws {
        guard let projected else { return }
        let localCommands = Set(state.safeProjectionCommands().map(\.id))
        let localTasks = Set(state.safeProjectionTaskOperations().map(\.id))
        let localDurations = Set(state.safeProjectionDurationOperations().map(\.id))
        let localAuto = Set(state.safeProjectionAutoStartOperations().map { $0.id.uuidString.lowercased() })
        let localSelected = Set(state.safeProjectionSelectedTaskOperations().map { $0.id.uuidString.lowercased() })
        let coreCommands = Set(projected.commands.map(\.id))
        let coreTasks = Set(projected.taskOperations.map(\.id))
        let coreDurations = Set(projected.durationOperations.map(\.id))
        let coreAuto = Set(projected.autoStartOperations.map { $0.id.lowercased() })
        let coreSelected = Set(projected.selectedTaskOperations.map { $0.id.lowercased() })
        guard localCommands == coreCommands, localTasks == coreTasks,
              localDurations == coreDurations, localAuto == coreAuto,
              localSelected == coreSelected else {
            throw SharedCoreError.invalidResponse("reconcile.rebase.v2 projectionPending diverges from local safeProjection")
        }
    }

    private func coreTimerDependencies(
        in state: PersistedTimerState
    ) -> [CoreTimerDependency] {
        var dependencies = state.pendingTimerDependencies
        var children = Set(dependencies.map(\.operationId))
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
            if children.insert(provisional.startCommandId).inserted {
                dependencies.append(CoreTimerDependency(
                    operationId: provisional.startCommandId,
                    dependsOnOperationId: provisional.finishCommandId,
                    generatedBreak: true,
                    sourceDayStart: sourceDay.start,
                    sourceDayEnd: sourceDay.end
                ))
            }

            dependencies += legacyBreakChildren(
                after: startIndex, provisional: provisional,
                commands: state.pendingCommands, seen: &children
            )
        }
        return dependencies
    }

    private func legacyBreakChildren(
        after startIndex: Int,
        provisional: ProvisionalBreak,
        commands: [TimerCommand],
        seen: inout Set<String>
    ) -> [CoreTimerDependency] {
        var dependencies: [CoreTimerDependency] = []
        var parentID = provisional.startCommandId
        for command in commands.suffix(from: startIndex + 1) {
            if command.type == .start { break }
            guard command.timerId == provisional.breakTimerId else { continue }
            if seen.insert(command.id).inserted {
                dependencies.append(CoreTimerDependency(
                    operationId: command.id, dependsOnOperationId: parentID
                ))
            }
            parentID = command.id
        }
        return dependencies
    }

    private func resolveProvisionalPhaseAdvances(
        in state: inout PersistedTimerState,
        acknowledgements: [Acknowledgement],
        canonicalHistory: [HistoryItem],
        canonicalTimer: CanonicalTimer?
    ) throws {
        let acknowledgementsByID = try Self.acknowledgementsByID(acknowledgements)
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
    ) throws {
        let acknowledgementsByID = try Self.acknowledgementsByID(acknowledgements)
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
                ? String(localized: "Server resolved a timer action.")
                : conflict.reason
        }
        if let conflict = response.taskAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a task change.")
                : conflict.reason
        }
        if let conflict = response.durationAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a duration change.")
                : conflict.reason
        }
        if let conflict = response.autoStartAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved an auto-start change.")
                : conflict.reason
        }
        if let conflict = response.selectedTaskAcknowledgements.first(where: { $0.outcome == .rejected }) {
            return conflict.reason.isEmpty
                ? String(localized: "Server resolved a selected-task change.")
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
        state.legacyTimerDependencyUpgrade = false
        state.legacyUnresolvedCommandIDs = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        if request.autoStartOperations != nil { state.pendingAutoStartOperations = [] }
        if request.selectedTaskOperations != nil { state.pendingSelectedTaskOperations = [] }
        state.localTimerOwners = [:]
        state.provisionalBreaks = []
        state.pendingTimerDependencies = []
        state.provisionalPhaseAdvances = []
        state.knownTasks = response.tasks
        state.legacyTaskAssignments = [:]
        state.pruneNeverSentProofToPending()
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

enum LegacyTimerDependencyReview: LocalizedError {
    case required

    var errorDescription: String? {
        String(localized: "Sync paused: older saved timer actions lack dependency provenance. Your queued actions remain unchanged. Contact support to review them before syncing this device.")
    }
}

// Old schema records no source command ID after a focus Finish ACK removes
// provisionalBreaks. Quarantine every old command identity, including a lone
// child Finish; no shape or never-sent proof can establish missing provenance.
private enum LegacyBreakDependencyRecovery {
    static func requiresReview(_ state: PersistedTimerState) -> Bool {
        !state.legacyUnresolvedCommandIDs.isEmpty
            || (state.legacyTimerDependencyUpgrade && state.hasCorruptPendingOperations)
    }
}

// AP88: duplicate server acks would trap in
// Dictionary(uniqueKeysWithValues:). Reject with invalidResponse instead.
// Internal so tests drive duplicate vs distinct acks directly.
extension AccountSynchronization {
    nonisolated static func acknowledgementsByID(
        _ acknowledgements: [Acknowledgement]
    ) throws -> [String: Acknowledgement] {
        let ids = acknowledgements.map(\.commandId)
        guard Set(ids).count == ids.count else { throw AppError.invalidResponse }
        return Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) })
    }
}
