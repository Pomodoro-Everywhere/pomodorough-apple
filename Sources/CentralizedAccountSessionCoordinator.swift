import Foundation

@MainActor
final class CentralizedAccountSessionCoordinator {
    typealias Operation = AccountLifecycleController.Operation

    private let lifecycle: AccountLifecycleController
    private let synchronization: AccountSynchronization
    private let persistence: AppStatePersistenceCoordinator
    private(set) var publication: PublicationSnapshot
    private var syncOwnership = SyncOwnership()
    private var bootstrapSnapshot: BootstrapResponse?

    init(
        lifecycle: AccountLifecycleController,
        synchronization: AccountSynchronization,
        initialPublication: PublicationSnapshot,
        persistence: AppStatePersistenceCoordinator = AppStatePersistenceCoordinator(defaults: .standard)
    ) {
        self.lifecycle = lifecycle
        self.synchronization = synchronization
        self.persistence = persistence
        publication = initialPublication
    }
}

extension CentralizedAccountSessionCoordinator {
    struct PublicationSnapshot: Equatable, Sendable {
        var sessionState: AccountSessionState
        var isSyncing: Bool
        var isOffline: Bool
        var historyResolutionState: AccountHistoryResolutionState
        var localHistoryResolutionCount: Int
        var remoteHistoryResolutionCount: Int

        init(
            sessionState: AccountSessionState,
            isSyncing: Bool = false,
            isOffline: Bool = false,
            historyResolutionState: AccountHistoryResolutionState = .none,
            localHistoryResolutionCount: Int = 0,
            remoteHistoryResolutionCount: Int = 0
        ) {
            self.sessionState = sessionState
            self.isSyncing = isSyncing
            self.isOffline = isOffline
            self.historyResolutionState = historyResolutionState
            self.localHistoryResolutionCount = localHistoryResolutionCount
            self.remoteHistoryResolutionCount = remoteHistoryResolutionCount
        }
    }

    struct Transition<Action: Sendable>: Sendable {
        let publication: PublicationSnapshot
        let action: Action
        let effects: [Effect]
    }

    enum Effect: Equatable, Sendable {
        case resetCentralizedLifecycle
        case signOutIdentity
        case cancelRetry
        case scheduleRetry
        case cancelCentralizedStreams
        case startCentralizedStreams
        case persist
        case rebuildProjection
        case removeLegacyTasks
        case reportInvalidPendingOperations
        case presentError(String)
        case presentPersistenceFailure(String, quarantined: Bool)
    }
}

extension CentralizedAccountSessionCoordinator {
    enum RestoreAction: Equatable, Sendable {
        case ignored
        case localOnly
        case verify(Operation)
        case unauthorized(Operation)
    }

    enum SignInStartAction: Equatable, Sendable {
        case ignored
        case started(Operation)
    }

    enum AuthenticationAction: Equatable, Sendable {
        case stale
        case authenticated(User, Operation)
        case failed(String)
    }

    struct ResetAction: Equatable, Sendable {
        let operation: Operation
        let isWorking: Bool?
    }

    enum VerificationAction: Equatable, Sendable {
        case ignored
        case verified(User, Operation)
        case unauthorized(Operation)
        case retry
    }

    enum BootstrapRetryAction: Equatable, Sendable {
        case signIn
        case verify(Operation)
        case submit(BootstrapResolveRequest, Operation)
        case preflight(Operation)
    }

    enum BootstrapFailureAction: Equatable, Sendable {
        case stale
        case unauthorized(Operation)
        case restartPreflight
        case retryable
    }
}

extension CentralizedAccountSessionCoordinator {
    func restore(cachedUser: User?) async -> Transition<RestoreAction> {
        let operation = currentOperation
        switch await lifecycle.restore(cachedUser: cachedUser) {
        case .stale:
            return transition(.ignored)
        case .localOnly(let invalidatesSynchronization):
            if invalidatesSynchronization { invalidateSynchronization() }
            publication.sessionState = .localOnly
            return transition(.localOnly)
        case .signedIn(let user):
            publication.sessionState = .signedIn(user)
            return transition(.verify(operation))
        case .unauthorized:
            return transition(.unauthorized(operation))
        }
    }

    func beginSignIn(isWorking: Bool) -> Transition<SignInStartAction> {
        guard let result = lifecycle.beginSignIn(isWorking: isWorking) else {
            return transition(.ignored)
        }
        return transition(
            .started(result.operation),
            effects: coordinatorEffects(for: result.effects)
        )
    }

    func authenticate(
        _ operation: Operation,
        deviceID: String,
        platform: String
    ) async -> Transition<AuthenticationAction> {
        switch await lifecycle.authenticate(operation, deviceID: deviceID, platform: platform) {
        case .stale:
            return transition(.stale)
        case .authenticated(let user):
            publication.sessionState = .signedIn(user)
            publication.isOffline = false
            return transition(.authenticated(user, operation))
        case .failed(let message):
            return transition(.failed(message))
        }
    }

    func verifyRestoredSession(
        _ operation: Operation,
        hasAccountState: Bool
    ) async -> Transition<VerificationAction> {
        switch await lifecycle.verifyRestoredSession(
            operation,
            isSignedIn: signedInUser != nil,
            hasAccountState: hasAccountState
        ) {
        case .ignored:
            return transition(.ignored)
        case .verified(let user):
            publication.sessionState = .signedIn(user)
            publication.isOffline = false
            return transition(.verified(user, operation))
        case .unauthorized:
            return transition(.unauthorized(operation))
        case .retry:
            publication.isOffline = true
            return transition(.retry, effects: [.scheduleRetry])
        }
    }
}

extension CentralizedAccountSessionCoordinator {
    func beginAccountSwitchCancellation(
        hasPendingAccountSwitch: Bool,
        isWorking: Bool
    ) -> Transition<ResetAction>? {
        lifecycle.beginAccountSwitchCancellation(
            hasPendingAccountSwitch: hasPendingAccountSwitch,
            isWorking: isWorking
        ).map(applyReset)
    }

    func beginSignOut(
        isWorking: Bool,
        preservesBootstrapResolution: Bool,
        pendingStrategy: BootstrapResolutionStrategy?
    ) -> Transition<ResetAction>? {
        lifecycle.beginSignOut(
            isWorking: isWorking,
            preservesBootstrapResolution: preservesBootstrapResolution,
            pendingStrategy: pendingStrategy
        ).map(applyReset)
    }

    func completeDeletion() -> Transition<ResetAction> {
        applyReset(lifecycle.completeDeletion())
    }

    func invalidateUnauthorized(
        _ operation: Operation,
        preservesBootstrapResolution: Bool,
        pendingStrategy: BootstrapResolutionStrategy?
    ) -> Transition<ResetAction>? {
        lifecycle.invalidateUnauthorized(
            operation,
            preservesBootstrapResolution: preservesBootstrapResolution,
            pendingStrategy: pendingStrategy
        ).map(applyReset)
    }

    func confirmAccountSwitch(
        state: PersistedTimerState,
        authenticatedUser: User?
    ) -> PersistedTimerState? {
        guard let updated = lifecycle.confirmAccountSwitch(
            state: state,
            authenticatedUser: authenticatedUser
        )?.state else { return nil }
        clearBootstrapPresentation()
        return updated
    }

    func signedOutStorageTransition(
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        preservesBootstrapResolution: Bool,
        activeReturnState: PersistedTimerState?
    ) -> AccountLifecycleController.SignedOutStorageTransition {
        lifecycle.signedOutStorageTransition(
            state: state,
            replicationMode: replicationMode,
            preservesBootstrapResolution: preservesBootstrapResolution,
            activeReturnState: activeReturnState
        )
    }

    func logout() async { await lifecycle.logout() }
    func clearTokens() async { await lifecycle.clearTokens() }
    func deleteAccount(confirmation: String) async -> String? {
        await lifecycle.deleteAccount(confirmation: confirmation)
    }
    func signOutIdentity() { lifecycle.signOutIdentity() }
    func handleGoogleSignInURL(_ url: URL) -> Bool { lifecycle.handleGoogleSignInURL(url) }

    func bootstrapRetryAction(
        pendingRequest: BootstrapResolveRequest?
    ) -> BootstrapRetryAction {
        switch lifecycle.bootstrapRetryAction(
            isSignedIn: signedInUser != nil,
            pendingRequest: pendingRequest
        ) {
        case .signIn: .signIn
        case .verify(let operation): .verify(operation)
        case .submit(let request, let operation): .submit(request, operation)
        case .preflight(let operation): .preflight(operation)
        }
    }
}

extension CentralizedAccountSessionCoordinator {
    struct Workspace: Equatable, Sendable {
        let state: PersistedTimerState
        let replicationMode: ReplicationMode
        let modeGeneration: Int
        let isMutationBlocked: Bool

        var hasPendingOperations: Bool {
            !state.pendingCommands.isEmpty
                || !state.pendingTaskOperations.isEmpty
                || !state.pendingDurationOperations.isEmpty
                || !state.pendingAutoStartOperations.isEmpty
                || !state.pendingSelectedTaskOperations.isEmpty
        }
    }

    struct SyncLease: Equatable, Sendable {
        let id: UUID
        let operation: Operation
        let modeGeneration: Int
        let showsActivity: Bool
    }

    enum SyncStartAction: Equatable, Sendable {
        case ignored
        case coalesced
        case verify(Operation)
        case invalidPendingOperations
        case started(SyncLease)
    }

    enum SyncFinishAction: Equatable, Sendable {
        case ignored
        case synchronize
    }

    enum SyncRoundsAction: Equatable, Sendable {
        case ignored
        case completed
    }

    struct PersistenceAction: Equatable, Sendable {
        let state: PersistedTimerState
        let succeeded: Bool
    }
}

extension CentralizedAccountSessionCoordinator {
    var currentOperation: Operation { lifecycle.currentOperation }
    var generation: Int { lifecycle.generation }

    func operation(generation: Int) -> Operation {
        Operation(generation: generation)
    }

    func owns(_ operation: Operation) -> Bool { lifecycle.owns(operation) }
    func isVerified(_ operation: Operation) -> Bool { lifecycle.isVerified(operation) }

    func markCurrentSessionVerified() {
        lifecycle.markVerified(currentOperation)
    }

    func beginSync(
        workspace: Workspace,
        force: Bool,
        showsActivity: Bool
    ) -> Transition<SyncStartAction> {
        guard canSynchronize(workspace) else { return transition(.ignored) }
        let operation = currentOperation
        guard lifecycle.isVerified(operation) else { return transition(.verify(operation)) }
        guard workspace.state.cachedUser?.id == signedInUser?.id else {
            return transition(.ignored)
        }
        guard workspace.state.hasValidPendingWireOperationsForResample else {
            publication.isOffline = false
            return transition(
                .invalidPendingOperations,
                effects: [.reportInvalidPendingOperations]
            )
        }
        guard force || workspace.hasPendingOperations else { return transition(.ignored) }
        guard let id = syncOwnership.begin(generation: operation.generation) else {
            return transition(.coalesced)
        }
        if showsActivity { publication.isSyncing = true }
        return transition(
            .started(SyncLease(
                id: id, operation: operation,
                modeGeneration: workspace.modeGeneration, showsActivity: showsActivity
            )),
            effects: [.cancelRetry]
        )
    }
}

extension CentralizedAccountSessionCoordinator {
    func finishSync(
        _ lease: SyncLease,
        workspace: Workspace,
        hintedFollowUp: Bool,
        allowsFollowUp: Bool
    ) -> Transition<SyncFinishAction> {
        guard let requested = syncOwnership.finish(
            lease.id, currentGeneration: lifecycle.generation
        ) else { return transition(.ignored) }
        if lease.showsActivity { publication.isSyncing = false }
        let localFollowUp = requested && workspace.hasPendingOperations
        let remoteFollowUp = ownsCentralizedReplication(
            lease.operation,
            modeGeneration: lease.modeGeneration,
            workspace: workspace
        ) && hintedFollowUp
        guard allowsFollowUp,
              canSynchronize(workspace),
              lease.modeGeneration == workspace.modeGeneration,
              localFollowUp || remoteFollowUp else { return transition(.ignored) }
        return transition(.synchronize)
    }

    func ownsSyncLease(_ lease: SyncLease) -> Bool {
        syncOwnership.isOwned(by: lease.id)
    }

    func finishSyncRounds(
        _ lease: SyncLease,
        workspace: Workspace
    ) -> Transition<SyncRoundsAction> {
        guard ownsCentralizedReplication(
            lease.operation,
            modeGeneration: lease.modeGeneration,
            workspace: workspace
        ) else { return transition(.ignored) }
        return transition(.completed, effects: [.startCentralizedStreams])
    }

    func quiesce() -> PublicationSnapshot {
        syncOwnership.invalidate()
        publication.isSyncing = false
        return publication
    }

    func ownsCentralizedReplication(
        _ operation: Operation,
        modeGeneration: Int,
        workspace: Workspace
    ) -> Bool {
        lifecycle.owns(operation)
            && workspace.replicationMode == .centralized
            && workspace.modeGeneration == modeGeneration
    }

    private func canSynchronize(_ workspace: Workspace) -> Bool {
        workspace.replicationMode == .centralized
            && signedInUser != nil
            && !workspace.isMutationBlocked
    }
}

extension CentralizedAccountSessionCoordinator {
    enum AuthenticatedRouteAction: Equatable, Sendable {
        case ignored
        case invalidPendingOperations
        case stageAccountSwitch(PersistedTimerState)
        case stageNoncentralized(PersistedTimerState)
        case resumeCached(PersistedTimerState)
        case bootstrap(PersistedTimerState, BootstrapResolveRequest?)
    }

    func routeAuthenticatedSession(
        _ user: User,
        operation: Operation,
        state: PersistedTimerState,
        replicationMode: ReplicationMode
    ) -> Transition<AuthenticatedRouteAction> {
        guard lifecycle.owns(operation), signedInUser?.id == user.id else {
            return transition(.ignored)
        }
        guard state.hasValidPendingWireOperationsForResample else {
            publication.isOffline = false
            return transition(
                .invalidPendingOperations,
                effects: [.reportInvalidPendingOperations]
            )
        }
        if let staged = lifecycle.stageAccountSwitch(to: user, state: state)?.state {
            clearBootstrapPresentation()
            return transition(
                .stageAccountSwitch(staged),
                effects: [.cancelCentralizedStreams, .persist]
            )
        }
        if replicationMode != .centralized {
            return routeNoncentralized(user, state: state)
        }
        if state.cachedUser != nil {
            var resumed = state
            resumed.prepare(for: user)
            clearBootstrapPresentation()
            return transition(
                .resumeCached(resumed), effects: [.rebuildProjection, .persist]
            )
        }
        return beginBootstrap(user, state: state)
    }
}

private extension CentralizedAccountSessionCoordinator {
    func routeNoncentralized(
        _ user: User,
        state: PersistedTimerState
    ) -> Transition<AuthenticatedRouteAction> {
        var staged = state
        if staged.cachedUser?.id != user.id {
            if staged.bootstrapUser?.id != user.id {
                staged.pendingBootstrapResolution = nil
            }
            staged.cachedUser = nil
            staged.bootstrapUser = user
        }
        publication.historyResolutionState = .none
        return transition(.stageNoncentralized(staged), effects: [.persist])
    }

    func beginBootstrap(
        _ user: User,
        state: PersistedTimerState
    ) -> Transition<AuthenticatedRouteAction> {
        var staged = state
        if staged.bootstrapUser?.id != user.id {
            staged.pendingBootstrapResolution = nil
        }
        staged.bootstrapUser = user
        return transition(
            .bootstrap(staged, staged.pendingBootstrapResolution), effects: [.persist]
        )
    }
}

extension CentralizedAccountSessionCoordinator {
    enum BootstrapPreflightAction: Sendable {
        case ignored
        case started
        case choose
        case submit(BootstrapResolutionStrategy, BootstrapResponse)
        case invalidResponse
    }

    enum BootstrapSubmissionAction: Equatable, Sendable {
        case ignored
        case started
        case unauthorized
        case retryPreflight
        case retryable
    }

    func beginBootstrapPreflight(
        operation: Operation,
        workspace: Workspace,
        user: User?
    ) -> Transition<BootstrapPreflightAction> {
        guard ownsCentralizedReplication(
            operation, modeGeneration: workspace.modeGeneration, workspace: workspace
        ), lifecycle.isVerified(operation), workspace.state.cachedUser == nil,
           workspace.state.bootstrapUser?.id == user?.id else {
            return transition(.ignored)
        }
        publication.historyResolutionState = .preflighting
        publication.isSyncing = false
        return transition(.started, effects: [.cancelRetry, .cancelCentralizedStreams])
    }
}

extension CentralizedAccountSessionCoordinator {
    func finishBootstrapPreflight(
        _ result: AccountSynchronization.BootstrapPreflightTransition,
        autoSubmits: Bool
    ) -> Transition<BootstrapPreflightAction> {
        bootstrapSnapshot = result.response
        publication.localHistoryResolutionCount = result.plan.localHistoryCount ?? 0
        publication.remoteHistoryResolutionCount = result.plan.remoteHistoryCount ?? 0
        publication.isOffline = false
        switch result.plan.mode {
        case .choose:
            publication.historyResolutionState = .choosing
            return transition(.choose)
        case .auto:
            guard autoSubmits, let strategy = result.plan.strategy else {
                publication.historyResolutionState = .retryable(result.plan.strategy)
                return transition(.choose)
            }
            return transition(.submit(strategy, result.response))
        case .normalSync:
            return transition(.invalidResponse)
        }
    }

    func requestHistoryResolution(
        _ strategy: BootstrapResolutionStrategy
    ) -> PublicationSnapshot {
        if publication.historyResolutionState == .choosing {
            publication.historyResolutionState = .confirming(strategy)
        }
        return publication
    }

    func cancelHistoryResolutionConfirmation() -> PublicationSnapshot {
        if case .confirming = publication.historyResolutionState {
            publication.historyResolutionState = .choosing
        }
        return publication
    }
}

extension CentralizedAccountSessionCoordinator {
    func confirmedHistoryResolution() -> (BootstrapResolutionStrategy, BootstrapResponse)? {
        guard case .confirming(let strategy) = publication.historyResolutionState,
              let bootstrapSnapshot else { return nil }
        return (strategy, bootstrapSnapshot)
    }

    func beginBootstrapSubmission(
        _ request: BootstrapResolveRequest,
        operation: Operation,
        workspace: Workspace,
        user: User?
    ) -> Transition<BootstrapSubmissionAction> {
        guard ownsCentralizedReplication(
            operation, modeGeneration: workspace.modeGeneration, workspace: workspace
        ), lifecycle.isVerified(operation), workspace.state.cachedUser == nil,
           workspace.state.bootstrapUser?.id == user?.id,
           workspace.state.pendingBootstrapResolution == request else {
            return transition(.ignored)
        }
        publication.historyResolutionState = .submitting(request.strategy)
        return transition(.started, effects: [.cancelRetry])
    }

}

extension CentralizedAccountSessionCoordinator {
    enum SyncFailureAction: Equatable, Sendable {
        case stale
        case unauthorized(Operation)
        case blocksFollowUp
        case schedulesRetry
    }

    func syncFailure(
        _ error: Error,
        lease: SyncLease,
        workspace: Workspace,
        pendingChangeCount: Int
    ) -> Transition<SyncFailureAction> {
        if case AppError.unauthorized = error {
            guard workspace.replicationMode == .centralized,
                  workspace.modeGeneration == lease.modeGeneration else {
                return transition(.stale)
            }
            return transition(.unauthorized(lease.operation))
        }
        guard ownsCentralizedReplication(
            lease.operation, modeGeneration: lease.modeGeneration, workspace: workspace
        ), signedInUser != nil else { return transition(.stale) }
        if error is SharedCoreError || error as? AppError == .invalidResponse
            || error as? AppError == .invalidLocalClock {
            publication.isOffline = false
            let message = String(localized: "Sync paused because the server response did not match queued changes. \(pendingChangeCount) queued changes remain on this device.")
            return transition(
                .blocksFollowUp,
                effects: [.presentError(message), .cancelCentralizedStreams]
            )
        }
        publication.isOffline = true
        return transition(.schedulesRetry, effects: [.scheduleRetry])
    }

    func markSyncSucceeded() -> PublicationSnapshot {
        publication.isOffline = false
        return publication
    }
}

extension CentralizedAccountSessionCoordinator {
    func bootstrapFailure(
        _ error: Error,
        stage: AccountLifecycleController.BootstrapStage,
        operation: Operation,
        modeGeneration: Int,
        workspace: Workspace
    ) -> Transition<BootstrapFailureAction> {
        guard ownsCentralizedReplication(
            operation, modeGeneration: modeGeneration, workspace: workspace
        ) else { return transition(.stale) }
        if case AppError.unauthorized = error {
            return transition(.unauthorized(operation))
        }
        guard signedInUser != nil else { return transition(.stale) }
        if case .submission = stage, case AppError.conflict = error {
            bootstrapSnapshot = nil
            return transition(.restartPreflight)
        }
        let failure = lifecycle.bootstrapFailure(error, stage: stage)
        publication.historyResolutionState = failure.historyResolutionState
        publication.isOffline = failure.isOffline
        var effects = coordinatorEffects(for: failure.effects)
        if let message = failure.errorMessage { effects.insert(.presentError(message), at: 0) }
        return transition(.retryable, effects: effects)
    }

    func finishBootstrapResolution() -> PublicationSnapshot {
        clearBootstrapPresentation()
        publication.isOffline = false
        return publication
    }

    func resetBootstrapAfterConflict() -> PublicationSnapshot {
        bootstrapSnapshot = nil
        return publication
    }
}

extension CentralizedAccountSessionCoordinator {
    func loadCompletionEffects(
        for transition: AppStatePersistenceCoordinator.LoadTransition,
        projectionSucceeded: Bool
    ) -> [Effect] {
        switch persistence.completionEffect(
            for: transition,
            projectionSucceeded: projectionSucceeded
        ) {
        case .none: []
        case .removeLegacyTasks: [.removeLegacyTasks]
        case .persist: [.persist]
        case .removeLegacyTasksAndPersist: [.removeLegacyTasks, .persist]
        case .reportInvalidLocalClock:
            [.presentPersistenceFailure(
                String(localized: "Saved sequence or trusted-time state is invalid. No local change was saved."),
                quarantined: false
            ), .presentError(AppError.invalidLocalClock.localizedDescription)]
        }
    }

    func removeLegacyTasks() {
        persistence.removeLegacyTasks()
    }

    func persist(
        _ state: PersistedTimerState,
        to destination: AppStatePersistenceCoordinator.Destination
    ) -> Transition<PersistenceAction> {
        let application = persistence.application(
            for: persistence.persist(state, to: destination),
            current: state,
            rebuildsOnFailure: true
        )
        var effects: [Effect] = []
        if application.rebuildsProjection { effects.append(.rebuildProjection) }
        appendPersistenceFailure(from: application, to: &effects)
        return transition(
            PersistenceAction(state: application.state, succeeded: application.succeeded),
            effects: effects
        )
    }

    func persistAtomically(
        previous: PersistedTimerState,
        proposed: PersistedTimerState,
        to destination: AppStatePersistenceCoordinator.Destination,
        rebuildsOnRollback: Bool
    ) -> Transition<PersistenceAction> {
        let application = persistence.application(
            for: persistence.persistAtomically(
                previous: previous,
                proposed: proposed,
                to: destination
            ),
            rebuildsOnRollback: rebuildsOnRollback
        )
        var effects: [Effect] = []
        appendPersistenceFailure(from: application, to: &effects)
        if application.rebuildsProjection { effects.append(.rebuildProjection) }
        return transition(
            PersistenceAction(state: application.state, succeeded: application.succeeded),
            effects: effects
        )
    }
}

extension CentralizedAccountSessionCoordinator {
    func makeSyncPlan(state: PersistedTimerState) -> AccountSynchronization.SyncPlan {
        synchronization.makeSyncPlan(state: state)
    }

    func sendSync(
        _ plan: AccountSynchronization.SyncPlan
    ) async throws -> TimedHTTPResponse<SyncResponse> {
        try await synchronization.sendSync(plan)
    }

    func reconcileSync(
        _ response: TimedHTTPResponse<SyncResponse>,
        plan: AccountSynchronization.SyncPlan,
        state: PersistedTimerState
    ) throws -> AccountSynchronization.SyncTransition {
        try synchronization.reconcileSync(response, plan: plan, state: state)
    }

    func sendBootstrapPreflight(
        state: PersistedTimerState
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        try await synchronization.sendBootstrapPreflight(state: state)
    }

    func reconcileBootstrapPreflight(
        _ response: TimedHTTPResponse<BootstrapResponse>,
        state: PersistedTimerState,
        localHistory: [HistoryItem],
        hasLocalState: Bool
    ) throws -> AccountSynchronization.BootstrapPreflightTransition {
        try synchronization.reconcileBootstrapPreflight(
            response, state: state, localHistory: localHistory, hasLocalState: hasLocalState
        )
    }
}

extension CentralizedAccountSessionCoordinator {
    func makeBootstrapResolutionRequest(
        strategy: BootstrapResolutionStrategy,
        snapshot: BootstrapResponse,
        state: PersistedTimerState
    ) -> BootstrapResolveRequest {
        synchronization.makeBootstrapResolutionRequest(
            strategy: strategy, snapshot: snapshot, state: state
        )
    }

    func validateBootstrapRequest(_ request: BootstrapResolveRequest, deviceID: String) throws {
        try synchronization.validateBootstrapRequest(request, deviceID: deviceID)
    }

    func sendBootstrapResolution(
        _ request: BootstrapResolveRequest
    ) async throws -> TimedHTTPResponse<BootstrapResponse> {
        try await synchronization.sendBootstrapResolution(request)
    }

    func reconcileBootstrapResolution(
        _ response: TimedHTTPResponse<BootstrapResponse>,
        request: BootstrapResolveRequest,
        state: PersistedTimerState,
        user: User
    ) throws -> AccountSynchronization.BootstrapResolutionTransition {
        try synchronization.reconcileBootstrapResolution(
            response, request: request, state: state, user: user
        )
    }
}

private extension CentralizedAccountSessionCoordinator {
    var signedInUser: User? {
        if case .signedIn(let user) = publication.sessionState { return user }
        return nil
    }

    func transition<Action: Sendable>(
        _ action: Action,
        effects: [Effect] = []
    ) -> Transition<Action> {
        Transition(publication: publication, action: action, effects: effects)
    }

    func applyReset(
        _ reset: AccountLifecycleController.ResetTransition
    ) -> Transition<ResetAction> {
        publication.sessionState = reset.sessionState
        if let offline = reset.isOffline { publication.isOffline = offline }
        if reset.clearsBootstrapPresentation { clearBootstrapPresentation() }
        if let history = reset.historyResolutionState {
            publication.historyResolutionState = history
        }
        return transition(
            ResetAction(operation: reset.operation, isWorking: reset.isWorking),
            effects: coordinatorEffects(for: reset.effects)
        )
    }

    func coordinatorEffects(
        for effects: [AccountLifecycleController.Effect]
    ) -> [Effect] {
        effects.compactMap { effect in
            switch effect {
            case .invalidateSynchronization:
                invalidateSynchronization()
                return nil
            case .resetCentralizedLifecycle:
                return .resetCentralizedLifecycle
            case .signOutIdentity:
                return .signOutIdentity
            case .scheduleRetry:
                return .scheduleRetry
            }
        }
    }

    func invalidateSynchronization() {
        syncOwnership.invalidate()
        publication.isSyncing = false
    }

    func appendPersistenceFailure(
        from application: AppStatePersistenceCoordinator.ApplicationTransition,
        to effects: inout [Effect]
    ) {
        guard let message = application.conflictMessage else { return }
        effects.append(.presentPersistenceFailure(
            message,
            quarantined: application.marksIrohConflict
        ))
    }

    func clearBootstrapPresentation() {
        bootstrapSnapshot = nil
        publication.historyResolutionState = .none
        publication.localHistoryResolutionCount = 0
        publication.remoteHistoryResolutionCount = 0
    }
}

#if DEBUG
extension CentralizedAccountSessionCoordinator {
    func installPreviewPublication(_ snapshot: PublicationSnapshot) -> PublicationSnapshot {
        publication = snapshot
        return publication
    }
}
#endif
