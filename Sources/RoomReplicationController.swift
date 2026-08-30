import Foundation

@MainActor
final class RoomReplicationController {
    private enum RevisionTaskContext {
        @TaskLocal static var id: UUID?
    }

    private struct RevisionTaskHandle {
        let id: UUID?
        let task: Task<Void, Never>?
    }

    private enum RevisionConnectionResult {
        case reconnect(after: Double)
        case stop
    }

    struct ServiceHandlers: Sendable {
        let status: IrohReplicationService.StatusHandler
        let projection: IrohReplicationService.ProjectionHandler
    }

    struct Dependencies {
        let roomStore: IrohRoomStore
        let retryDelay: Duration
        let centralizedState: @MainActor @Sendable () -> RoomReplicationCentralizedState
        let workspaceSnapshot: @MainActor @Sendable () -> RoomReplicationWorkspaceSnapshot
        let revisionEvents: @Sendable () async throws -> AsyncThrowingStream<Int64, Error>
        let sleep: @Sendable (Duration) async throws -> Void
        let secureRandomBytes: @Sendable (Int) -> Data
        let encodeInvite: @Sendable (String, String?, String, Data) throws -> String
        let makeService: @MainActor @Sendable (ServiceHandlers) -> any RoomReplicationServing
    }

    private let dependencies: Dependencies
    private let eventHandler: @MainActor @Sendable (RoomReplicationEvent) -> Void
    private let operationHandler: @MainActor @Sendable (RoomReplicationOperation) async -> Void
    private var mode: ReplicationMode
    private(set) var modeGeneration = 0
    private var revisionLifecycle = RevisionStreamLifecycle()
    private var revisionHints = RevisionHintCoalescer()
    private var revisionStreamTask: Task<Void, Never>?
    private var revisionStreamTaskID: UUID?
    private var remotePollingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var endpointStartupTask: Task<Void, Never>?
    private var accountDeletionQuarantined = false
    private var sceneIsActive = false
    private lazy var service = dependencies.makeService(.init(
        status: { [weak self] status in self?.eventHandler(.statusChanged(status)) },
        projection: { [weak self] roomID, state in
            self?.eventHandler(.projectionReceived(.init(roomID: roomID, state: state)))
        }
    ))

    init(
        mode: ReplicationMode,
        dependencies: Dependencies,
        eventHandler: @escaping @MainActor @Sendable (RoomReplicationEvent) -> Void,
        operationHandler: @escaping @MainActor @Sendable (RoomReplicationOperation) async -> Void
    ) {
        self.mode = mode
        self.dependencies = dependencies
        self.eventHandler = eventHandler
        self.operationHandler = operationHandler
    }

    deinit {
        revisionStreamTask?.cancel()
        remotePollingTask?.cancel()
        retryTask?.cancel()
        endpointStartupTask?.cancel()
    }

    func ownership(sessionGeneration: Int) -> RoomReplicationOwnership {
        RoomReplicationOwnership(
            sessionGeneration: sessionGeneration,
            modeGeneration: modeGeneration
        )
    }

    func owns(_ owner: RoomReplicationOwnership, sessionGeneration: Int) -> Bool {
        owner.sessionGeneration == sessionGeneration
            && owner.modeGeneration == modeGeneration
            && mode == .centralized
    }

    func setSceneActive(_ active: Bool, environment: RoomReplicationEnvironment) {
        sceneIsActive = active
        revisionLifecycle.setActive(active)
        if !active { cancelCentralizedStreams() }
        guard mode == .iroh else { return }
        Task { [weak self] in
#if os(iOS)
            if active {
                await self?.startIrohIfNeeded(environment: environment)
            } else {
                await self?.service.stop()
            }
#else
            await self?.startIrohIfNeeded(environment: environment)
#endif
        }
    }

    func refreshAfterForeground(
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationForegroundAction {
        if mode == .iroh {
            await startIrohIfNeeded(environment: environment)
            await service.syncNow()
            return .none
        }
        guard mode == .centralized else { return .none }
        let state = dependencies.centralizedState()
        guard state.isSignedIn else { return .none }
        if !state.isWorkspaceMutationBlocked { startCentralizedStreams() }
        return .synchronize
    }

    func changeMode(
        to target: ReplicationMode,
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationTransition {
        guard target != mode else {
            if target == .iroh { scheduleIrohStartup(environment: environment) }
            return .unchanged
        }
        cancelEndpointStartup()
        let leavingCentralized = mode == .centralized && target != .centralized
        if leavingCentralized { quiesceCentralized() }
        let prepared = await prepareState(
            for: target,
            environment: environment,
            resumesCentralized: leavingCentralized
        )
        guard case .captured(let preparedState) = prepared else { return prepared }
        applyMode(target)
        return .modeChanged(target, preparedState)
    }

    private func prepareState(
        for target: ReplicationMode,
        environment: RoomReplicationEnvironment,
        resumesCentralized: Bool
    ) async -> RoomReplicationTransition {
        var preparedState = dependencies.workspaceSnapshot().state
        if mode == .iroh {
            await service.stop()
            do {
                preparedState = try dependencies.roomStore.captureAndSuspendActiveRoom(
                    from: dependencies.workspaceSnapshot().state
                )
            } catch {
                await startIrohIfNeeded(environment: environment)
                if resumesCentralized { resumeCentralized() }
                return .failed(error.localizedDescription)
            }
        }
        return activateTarget(
            target,
            state: preparedState,
            resumesCentralized: resumesCentralized
        )
    }

    private func activateTarget(
        _ target: ReplicationMode,
        state: PersistedTimerState,
        resumesCentralized: Bool
    ) -> RoomReplicationTransition {
        guard target == .iroh else { return .captured(state) }
        guard let roomID = dependencies.roomStore.preferredRoomID else {
            if resumesCentralized { resumeCentralized() }
            return .failed(String(localized: "Create or join an Iroh room before selecting Iroh mode."))
        }
        do {
            return .captured(try dependencies.roomStore.activateExistingRoom(
                roomID: roomID,
                returnState: state
            ))
        } catch {
            if resumesCentralized { resumeCentralized() }
            return .failed(error.localizedDescription)
        }
    }

    private func applyMode(_ target: ReplicationMode) {
        mode = target
        if target != .centralized { cancelCentralizedStreams() }
    }

    func createRoom(
        name rawName: String,
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationTransition {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= 64 else {
            return .failed(String(localized: "Room name must be 64 characters or fewer."))
        }
        let resumesCentralized = mode == .centralized
        if resumesCentralized { quiesceCentralized() }
        do {
            return try await createPreparedRoom(
                name: name,
                environment: environment
            )
        } catch {
            await service.stop()
            if resumesCentralized { resumeCentralized() }
            return .failed(error.localizedDescription)
        }
    }

    private func createPreparedRoom(
        name: String,
        environment: RoomReplicationEnvironment
    ) async throws -> RoomReplicationTransition {
        let secret = dependencies.secureRandomBytes(32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let ticket = try await service.start(context(
            roomID: roomID,
            secret: secret,
            environment: environment
        ))
        let workspace = dependencies.workspaceSnapshot()
        let returnState = dependencies.roomStore.activeSnapshot?.conflict != nil
            ? dependencies.roomStore.activeReturnState ?? workspace.state
            : workspace.state
        let roomState = try dependencies.roomStore.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: name.isEmpty ? nil : name,
            returnState: returnState,
            genesis: workspace.genesis
        )
        mode = .iroh
        cancelCentralizedStreams()
        let invite = try dependencies.encodeInvite(roomID, name.isEmpty ? nil : name, ticket, secret)
        return .roomCreated(
            roomState,
            invite: invite,
            status: .listening(endpointMark: String(ticket.suffix(6)))
        )
    }

    func refreshInvite(environment: RoomReplicationEnvironment) async -> RoomReplicationTransition {
        guard let room = dependencies.roomStore.activeSnapshot,
              let secret = dependencies.roomStore.activeRoomSecret else { return .unchanged }
        do {
            await startIrohIfNeeded(environment: environment)
            let ticket = try await service.currentEndpointTicket()
            let invite = try dependencies.encodeInvite(room.roomID, room.roomName, ticket, secret)
            return .inviteRefreshed(invite)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func joinRoom(
        inviteText: String,
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationTransition {
        let resumesCentralized = mode == .centralized
        if resumesCentralized { quiesceCentralized() }
        var preparation: IrohRoomStore.JoinPreparation?
        do {
            let invite = try IrohRoomInvite.decode(
                inviteText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let returnState = dependencies.workspaceSnapshot().state
            let prepared = try prepareJoinedRoom(invite, state: returnState)
            if prepared.alreadyActive { return .unchanged }
            preparation = prepared
            let context = context(roomID: invite.roomID, secret: invite.roomSecret, environment: environment)
            _ = try await service.start(context)
            try await service.join(invite: invite)
            let joined = try dependencies.roomStore.activateJoinedRoom(
                roomID: invite.roomID,
                returnState: returnState
            )
            mode = .iroh
            cancelCentralizedStreams()
            return .roomJoined(joined)
        } catch {
            return await recoverFailedJoin(
                error,
                preparation: preparation,
                resumesCentralized: resumesCentralized,
                environment: environment
            )
        }
    }

    private func prepareJoinedRoom(
        _ invite: IrohRoomInvite, state: PersistedTimerState
    ) throws -> IrohRoomStore.JoinPreparation {
        try dependencies.roomStore.prepareJoinedRoom(
            roomID: invite.roomID,
            roomSecret: invite.roomSecret,
            name: invite.roomName,
            returnState: state,
            initialPeer: IrohPeer(
                endpointID: invite.endpointID,
                endpointTicket: invite.endpointTicket,
                deviceID: nil,
                displayName: nil,
                lastSeenAt: nil
            )
        )
    }

    private func recoverFailedJoin(
        _ error: Error,
        preparation: IrohRoomStore.JoinPreparation?,
        resumesCentralized: Bool,
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationTransition {
        var message = error.localizedDescription
        if preparation != nil || mode != .iroh { await service.stop() }
        if let preparation {
            do {
                try dependencies.roomStore.rollbackJoinedRoom(preparation)
            } catch {
                message = String(localized: "\(message) Room join rollback failed: \(error.localizedDescription)")
            }
        }
        if resumesCentralized { resumeCentralized() }
        if mode == .iroh { await startIrohIfNeeded(environment: environment) }
        return .failed(message)
    }

    func leaveRoom(
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationTransition {
        guard mode == .iroh else { return .unchanged }
        await service.stop()
        do {
            let returned = try dependencies.roomStore.captureAndSuspendActiveRoom(
                from: dependencies.workspaceSnapshot().state
            )
            mode = .offline
            return .roomLeft(returned)
        } catch {
            await startIrohIfNeeded(environment: environment)
            return .failed(error.localizedDescription)
        }
    }

    func syncIroh(environment: RoomReplicationEnvironment) async {
        guard mode == .iroh else { return }
        await startIrohIfNeeded(environment: environment)
        await service.syncNow()
    }

    func captureLocalState(_ state: PersistedTimerState) -> RoomReplicationTransition {
        let durableState = dependencies.roomStore.activeRoomState
        do {
            let captured = try dependencies.roomStore.captureLocalOperations(from: state)
            Task { [service] in await service.syncNow() }
            return .captured(captured)
        } catch {
            let quarantined = Self.isImmutableConflict(error)
            if quarantined {
                let roomID = dependencies.roomStore.activeRoomID
                Task { [service] in await service.markConflict(roomID: roomID) }
            }
            return .captureFailed(
                durableState,
                message: error.localizedDescription,
                quarantined: quarantined
            )
        }
    }

    private static func isImmutableConflict(_ error: Error) -> Bool {
        if case IrohProtocolError.immutableConflict = error { return true }
        return false
    }

    nonisolated static func secureRandomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map {
            _ in UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    func projectionTransition(for projection: RoomReplicationProjection) -> RoomReplicationTransition {
        guard mode == .iroh,
              dependencies.roomStore.activeRoomID == projection.roomID,
              let storedState = dependencies.roomStore.activeRoomState else { return .unchanged }
        var updated = storedState
        var errorMessage: String?
        if Self.advanceDefaultPhaseAfterCompletion(in: &updated) {
            do {
                updated = try dependencies.roomStore.captureLocalOperations(from: updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return .projectionApplied(updated, errorMessage: errorMessage)
    }

    static func bootstrapRoomState(
        mode: ReplicationMode,
        localState: PersistedTimerState,
        roomStore: IrohRoomStore
    ) -> (mode: ReplicationMode, state: PersistedTimerState) {
        guard mode == .iroh else { return (mode, localState) }
        guard var roomState = roomStore.activeRoomState else { return (.offline, localState) }
        if advanceDefaultPhaseAfterCompletion(in: &roomState) {
            _ = try? roomStore.captureLocalOperations(from: roomState)
        }
        return (.iroh, roomState)
    }

    private static func advanceDefaultPhaseAfterCompletion(
        in state: inout PersistedTimerState
    ) -> Bool {
        guard !state.hasExplicitPhaseSelection,
              let timer = state.canonicalTimer,
              timer.status == .completed else { return false }
        guard let nextPhase = TimerSessionController.derivedNextPhase(
            from: state.history,
            on: timer.anchorAt
        ), state.settings.selectedPhase != nextPhase else { return false }
        state.settings.selectedPhase = nextPhase
        return true
    }

    func startIrohIfNeeded(environment: RoomReplicationEnvironment) async {
        guard let context = activeContext(environment: environment) else { return }
        do {
            _ = try await service.start(context)
        } catch {
            eventHandler(.statusChanged(.unavailable(error.localizedDescription)))
        }
    }

    func scheduleIrohStartup(environment: RoomReplicationEnvironment) {
        cancelEndpointStartup()
        guard let context = activeContext(environment: environment) else { return }
        endpointStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.service.start(context)
            } catch {
                guard !Task.isCancelled,
                      self.mode == .iroh,
                      self.dependencies.roomStore.activeRoomID == context.roomID else { return }
                self.eventHandler(.statusChanged(.unavailable(error.localizedDescription)))
            }
        }
    }

    private func activeContext(environment: RoomReplicationEnvironment) -> IrohServiceContext? {
        guard !accountDeletionQuarantined,
              mode == .iroh,
              let room = dependencies.roomStore.activeSnapshot,
              room.conflict == nil,
              let secret = dependencies.roomStore.activeRoomSecret else { return nil }
#if os(iOS)
        guard sceneIsActive else { return nil }
#endif
        return context(roomID: room.roomID, secret: secret, environment: environment)
    }

    private func context(
        roomID: String,
        secret: Data,
        environment: RoomReplicationEnvironment
    ) -> IrohServiceContext {
        IrohServiceContext(
            roomID: roomID,
            roomSecret: secret,
            deviceID: environment.deviceID,
            displayName: environment.displayName,
            platform: environment.platform
        )
    }

    private func cancelEndpointStartup() {
        endpointStartupTask?.cancel()
        endpointStartupTask = nil
    }

    func quiesceCentralized() {
        modeGeneration += 1
        retryTask?.cancel()
        retryTask = nil
        cancelCentralizedStreams()
        eventHandler(.centralizedQuiesced)
    }

    func resumeCentralized() {
        guard mode == .centralized else { return }
        let state = dependencies.centralizedState()
        guard state.isSignedIn else { return }
        startCentralizedStreams()
        Task { [weak self] in
            await self?.operationHandler(.synchronize(force: true, showsActivity: true))
        }
    }

    func cancelCentralizedStreams() {
        _ = cancelCentralizedStreamsRetainingRevisionTask()
    }

    private func cancelCentralizedStreamsRetainingRevisionTask() -> RevisionTaskHandle {
        revisionLifecycle.cancelCurrent()
        let revisionTask = RevisionTaskHandle(
            id: revisionStreamTaskID,
            task: revisionStreamTask
        )
        revisionTask.task?.cancel()
        revisionStreamTask = nil
        revisionStreamTaskID = nil
        remotePollingTask?.cancel()
        remotePollingTask = nil
        return revisionTask
    }

    func resetCentralizedLifecycle() {
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        cancelCentralizedStreams()
    }

    func quiesceForAccountDeletion() async {
        accountDeletionQuarantined = true
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        let revisionTask = cancelCentralizedStreamsRetainingRevisionTask()
        let startup = endpointStartupTask
        startup?.cancel()
        endpointStartupTask = nil
        if revisionTask.id != RevisionTaskContext.id {
            await revisionTask.task?.value
        }
        await startup?.value
        await service.stop()
    }

    func rollbackAccountDeletion(
        environment: RoomReplicationEnvironment
    ) async -> RoomReplicationForegroundAction {
        guard accountDeletionQuarantined else { return .none }
        accountDeletionQuarantined = false
        if mode == .iroh {
            await startIrohIfNeeded(environment: environment)
            await service.syncNow()
            return .none
        }
        guard mode == .centralized, sceneIsActive else { return .none }
        let state = dependencies.centralizedState()
        guard state.isSignedIn, !state.isWorkspaceMutationBlocked else { return .none }
        startCentralizedStreams()
        return .synchronize
    }

    func startCentralizedStreams() {
        startRevisionStream()
        startRemotePolling()
    }

    func startRemotePolling() {
        let state = dependencies.centralizedState()
        guard canStartCentralized(state), remotePollingTask == nil else { return }
        let owner = ownership(sessionGeneration: state.sessionGeneration)
        remotePollingTask = Task { [weak self] in await self?.pollingLoop(owner: owner) }
    }

    private func pollingLoop(owner: RoomReplicationOwnership) async {
        while !Task.isCancelled, ownsCurrent(owner) {
            let interval = RemotePolling.interval(
                isTimerActive: dependencies.centralizedState().isTimerActive
            )
            do {
                try await dependencies.sleep(.seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled, ownsCurrent(owner) else { return }
            await operationHandler(.synchronize(force: true, showsActivity: false))
        }
    }

    func startRevisionStream() {
        let state = dependencies.centralizedState()
        guard canStartCentralized(state),
              let streamID = revisionLifecycle.begin() else { return }
        let owner = ownership(sessionGeneration: state.sessionGeneration)
        let taskID = UUID()
        revisionStreamTaskID = taskID
        revisionStreamTask = Task { [weak self] in
            await RevisionTaskContext.$id.withValue(taskID) {
                await self?.revisionLoop(owner: owner, streamID: streamID)
            }
        }
    }

    private func revisionLoop(owner: RoomReplicationOwnership, streamID: UUID) async {
        var delay = 1.0
        while !Task.isCancelled, ownsCurrent(owner, streamID: streamID) {
            let result = await consumeRevisionEvents(owner: owner, streamID: streamID, delay: delay)
            guard case .reconnect(let nextDelay) = result,
                  await waitForRevisionReconnect(nextDelay) else { return }
            delay = min(nextDelay * 2, 30)
        }
    }

    private func consumeRevisionEvents(
        owner: RoomReplicationOwnership,
        streamID: UUID,
        delay: Double
    ) async -> RevisionConnectionResult {
        var nextDelay = delay
        do {
            let events = try await dependencies.revisionEvents()
            for try await revision in events {
                guard !Task.isCancelled, ownsCurrent(owner, streamID: streamID) else { return .stop }
                nextDelay = 1
                await receiveRevisionHint(revision)
            }
            return .reconnect(after: nextDelay)
        } catch is CancellationError {
            return .stop
        } catch AppError.unauthorized {
            return await handleUnauthorizedRevisionStream(owner: owner, streamID: streamID)
        } catch {
            return ownsCurrent(owner, streamID: streamID) && !Task.isCancelled
                ? .reconnect(after: nextDelay) : .stop
        }
    }

    private func handleUnauthorizedRevisionStream(
        owner: RoomReplicationOwnership,
        streamID: UUID
    ) async -> RevisionConnectionResult {
        guard ownsCurrent(owner, streamID: streamID) else { return .stop }
        await operationHandler(.unauthorized(sessionGeneration: owner.sessionGeneration))
        return .stop
    }

    private func waitForRevisionReconnect(_ delay: Double) async -> Bool {
        do {
            try await dependencies.sleep(.seconds(delay))
            return true
        } catch {
            return false
        }
    }

    func receiveRevisionHint(_ revision: Int64) async {
        let state = dependencies.centralizedState()
        if revisionHints.receive(
            revision,
            localRevision: state.localRevision,
            isSyncing: state.isSyncing
        ) {
            await operationHandler(.synchronize(force: true, showsActivity: true))
        }
    }

    func consumeRevisionFollowUp() -> Bool {
        revisionHints.consumeFollowUp(localRevision: dependencies.centralizedState().localRevision)
    }

    func scheduleRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        let owner = dependencies.centralizedState().sessionGeneration
        retryTask = Task { [weak self] in await self?.retryAfterDelay(sessionGeneration: owner) }
    }

    private func retryAfterDelay(sessionGeneration: Int) async {
        do {
            try await dependencies.sleep(dependencies.retryDelay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        retryTask = nil
        let state = dependencies.centralizedState()
        guard state.sessionGeneration == sessionGeneration else { return }
        await operationHandler(.retry(
            sessionGeneration: sessionGeneration,
            resolvesHistory: state.isHistoryResolutionBlocking
        ))
    }

    func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func canStartCentralized(_ state: RoomReplicationCentralizedState) -> Bool {
        mode == .centralized
            && state.isSignedIn
            && !state.isWorkspaceMutationBlocked
            && state.isSessionVerified
            && revisionLifecycle.isActive
    }

    private func ownsCurrent(_ owner: RoomReplicationOwnership, streamID: UUID? = nil) -> Bool {
        let state = dependencies.centralizedState()
        guard owns(owner, sessionGeneration: state.sessionGeneration), state.isSignedIn else { return false }
        return streamID.map(revisionLifecycle.owns) ?? revisionLifecycle.isActive
    }
}
