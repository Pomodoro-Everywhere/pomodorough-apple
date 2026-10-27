import Foundation
import Observation
import OSLog

private enum AccountDeletionPurgeState: String {
    case prepared
    case remoteCommitted = "remote_committed"
}

/// Durable-write step that failed without a thrown error (UserDefaults
/// read-back mismatch during account-deletion cleanup). Bare step name:
/// Sentry groups one issue per failed write.
private struct AccountDeletionDurableWriteError: Error, Sendable {
    let step: String
}

extension AccountDeletionDurableWriteError: LocalizedError {
    var errorDescription: String? { step }
}

private struct InitialAppState {
    let transition: AppStatePersistenceCoordinator.LoadTransition
    let replicationMode: ReplicationMode
    let physicalAnchor: (wall: Date, uptime: TimeInterval)?
    let needsPermissionIntroduction: Bool
}

private struct AccountDeletionRecovery {
    let record: AccountDeletionJournal.Record?
    let purgeState: AccountDeletionPurgeState?
}

private struct AppModelStartup {
    let accountDeletionJournal: AccountDeletionJournal?
    let timerSessionController: TimerSessionController
    let persistence: AppStatePersistenceCoordinator
    let initialState: InitialAppState
    let accountDeletionRecovery: AccountDeletionRecovery
}

private struct AppModelCoordinators {
    let workspaceMutationController: SynchronizedWorkspaceMutationController
    let accountSessionCoordinator: CentralizedAccountSessionCoordinator
    let alarmEffectCoordinator: AlarmEffectCoordinator
}

struct SyncFailureDiagnostics: Error, LocalizedError, Sendable {
    enum Stage: String, Sendable { case preSend, possibleDelivery, reconciliation, commit }
    enum Rollback: String, Sendable { case restored, snapshotChanged, deliveryPossible, notEligible, persistenceFailed }
    enum Reason: String, Sendable { case cancelled, transport, core, invalidResponse, invalidLocalClock, batch, other }
    let stage: Stage
    let rollback: Rollback
    let reason: Reason
    let pending: [Int]
    let hasClaim: Bool

    init(error: Error, stage: Stage, rollback: Rollback, state: PersistedTimerState) {
        self.stage = stage
        self.rollback = rollback
        reason = Self.reason(for: error)
        pending = [state.pendingCommands.count, state.pendingTaskOperations.count,
                   state.pendingDurationOperations.count, state.pendingAutoStartOperations.count,
                   state.pendingSelectedTaskOperations.count]
        hasClaim = state.outgoingSyncClaim != nil
    }

    private static func reason(for error: Error) -> Reason {
        switch error {
        case is CancellationError: .cancelled
        case let transport as URLError: transport.code == .cancelled ? .cancelled : .transport
        case is SharedCoreError: .core
        case AppError.invalidResponse: .invalidResponse
        case AppError.invalidLocalClock: .invalidLocalClock
        case is SyncBatchPlanError: .batch
        default: .other
        }
    }

    var key: String { "sync-boundary-\(stage.rawValue)-\(rollback.rawValue)-\(reason.rawValue)" }
    var warrantsCapture: Bool { reason == .core || reason == .invalidResponse || reason == .batch }
    var errorDescription: String? {
        "sync stage=\(stage.rawValue) rollback=\(rollback.rawValue) reason=\(reason.rawValue) "
            + "pending=\(pending.map(String.init).joined(separator: "/")) claim=\(hasClaim) "
            + "core=\(WorkspaceIntentProvenance.current().prefix(160))"
    }

    struct Budget {
        private var counts: [String: Int] = [:]
        mutating func record(_ diagnostic: SyncFailureDiagnostics) -> Bool {
            let count = counts[diagnostic.key, default: 0]
            guard count < 3 else { return false }
            counts[diagnostic.key] = count + 1
            return true
        }
    }
}

// R50-AP01: bounded account-switch confirm outcome. Counts only, no
// account IDs, titles, credentials, or payloads.
struct AccountSwitchConfirmDiagnostics: Error, LocalizedError, Sendable {
    enum Outcome: String, Sendable { case failed, uncertain }
    let outcome: Outcome
    let quarantined: Bool
    let pendingOperations: Int

    var key: String { "account-switch-confirm-\(outcome.rawValue)" }
    var errorDescription: String? {
        "account-switch stage=confirm outcome=\(outcome.rawValue) "
            + "quarantined=\(quarantined) pending=\(pendingOperations)"
    }
}

// R51-AP02: bounded account-switch cancel stage/outcome. Fixed stage
// and outcome with quarantine and pending counts only. No titles,
// account IDs, credentials, file payloads, or transport text.
struct AccountSwitchCancelDiagnostics: Error, LocalizedError, Sendable {
    enum Stage: String, Sendable { case credentials, persist }
    enum Outcome: String, Sendable { case failed, uncertain }
    let stage: Stage
    let outcome: Outcome
    let quarantined: Bool
    let pendingOperations: Int

    var key: String { "account-switch-cancel-\(stage.rawValue)-\(outcome.rawValue)" }
    var errorDescription: String? {
        "account-switch stage=cancel phase=\(stage.rawValue) outcome=\(outcome.rawValue) "
            + "quarantined=\(quarantined) pending=\(pendingOperations)"
    }
}

// R51-AP01: bounded sign-out stage/outcome. Fixed stage and outcome
// with quarantine and pending counts only. No titles, account IDs,
// credentials, file payloads, or transport text.
struct SignOutDiagnostics: Error, LocalizedError, Sendable {
    enum Stage: String, Sendable { case snapshot, localSnapshot, roomSnapshot, credentials, publish }
    enum Outcome: String, Sendable { case failed, uncertain }
    let stage: Stage
    let outcome: Outcome
    let quarantined: Bool
    let pendingOperations: Int

    var key: String { "sign-out-\(stage.rawValue)-\(outcome.rawValue)" }
    var errorDescription: String? {
        "sign-out stage=\(stage.rawValue) outcome=\(outcome.rawValue) "
            + "quarantined=\(quarantined) pending=\(pendingOperations)"
    }
}

// R52-AP02: bounded sign-out mutation-refusal outcome. Pending count
// only; no titles, account IDs, credentials, or transport text.
struct SignOutMutationRefusedDiagnostics: Error, LocalizedError, Sendable {
    let pendingOperations: Int

    var key: String { "sign-out-mutation-refused" }
    var errorDescription: String? {
        "sign-out stage=mutation outcome=refused pending=\(pendingOperations)"
    }
}

// R50-AP02: bounded bootstrap install outcome. Counts only, no timer
// IDs, titles, account IDs, or response bodies.
struct BootstrapInstallDiagnostics: Error, LocalizedError, Sendable {
    enum Outcome: String, Sendable { case failed, uncertain }
    let outcome: Outcome
    let quarantined: Bool
    let pendingOperations: Int

    var key: String { "bootstrap-install-\(outcome.rawValue)" }
    var errorDescription: String? {
        "bootstrap stage=install outcome=\(outcome.rawValue) "
            + "quarantined=\(quarantined) pending=\(pendingOperations)"
    }
}

// R50-AP03: bounded Iroh foreground refresh outcome. Backend and gate
// transition only, no room IDs, invites, secrets, or timer IDs.
struct IrohForegroundRefreshDiagnostics: Error, LocalizedError, Sendable {
    enum Outcome: String, Sendable { case released, retained }
    let outcome: Outcome
    let backend = "iroh"

    var key: String { "iroh-foreground-refresh-\(outcome.rawValue)" }
    var errorDescription: String? {
        "foreground backend=\(backend) outcome=\(outcome.rawValue)"
    }
}

@MainActor
private final class SyncDeliveryAttempt {
    var stage = SyncFailureDiagnostics.Stage.preSend
}

@MainActor
@Observable
final class AppModel {
    typealias SessionState = AccountSessionState
    typealias HistoryResolutionState = AccountHistoryResolutionState

    private static let logger = Logger(
        subsystem: "me.egigoka.pomodorough",
        category: "AppModel"
    )
    private let api: APIClient
    private let defaults: UserDefaults
    private let persistence: AppStatePersistenceCoordinator
    private let googleIdentityProvider: any GoogleIdentityProviding
    private let accountDeletionJournal: AccountDeletionJournal?
    private let roomStore: IrohRoomStore
    private let endpointKeyStore: any IrohEndpointKeyStoring
    private let roomServiceFactory: (@MainActor @Sendable (RoomReplicationController.ServiceHandlers) -> any RoomReplicationServing)?
    private let alarmScheduler: any TimerAlarmScheduling
    private let completionScheduler: TimerCompletionScheduler
    private let retryDelay: Duration
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let timerSessionController: TimerSessionController
    private let workspaceMutationController: SynchronizedWorkspaceMutationController
    private var accountSessionCoordinator: CentralizedAccountSessionCoordinator
    private let statePublisher = AppStatePublisher()
    private let alarmEffectCoordinator: AlarmEffectCoordinator
    private let taskIdentityCoreProvider: @MainActor () throws -> SharedCore
    private var timerState: PersistedTimerState
    private var accountDeletionPurgeState: AccountDeletionPurgeState?
    private var accountDeletionRecord: AccountDeletionJournal.Record?
    @ObservationIgnored private var alarmOperationTask: Task<Void, Never>?
    @ObservationIgnored private var timerCompletionTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledCompletionTimer: CanonicalTimer?
    @ObservationIgnored private var timerCompletionSuspensions = 0
    @ObservationIgnored private var centralizedSyncTask: Task<Bool, Never>?
    @ObservationIgnored private var centralizedSyncTaskID: UUID?
    @ObservationIgnored private var syncFailureDiagnosticBudget = SyncFailureDiagnostics.Budget()
    @ObservationIgnored private var completionQueuedFor: String?
    @ObservationIgnored private var physicalAnchor: (wall: Date, uptime: TimeInterval)?
    @ObservationIgnored private var taskIdentityCore: SharedCore?
    private var projectedAutoStartBreaks = false
    private var projectedSelectedTaskID: UUID?
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private var foregroundSyncPending = false
    @ObservationIgnored private lazy var roomReplicationController = makeRoomReplicationController()
    @ObservationIgnored let watchSync = WatchSyncService()

    private(set) var sessionState: SessionState = .restoring
    private(set) var canonicalTimer: CanonicalTimer?
    private(set) var history: [HistoryItem] = []
    private(set) var tasks: [FocusTask] = []
    private(set) var isWorking = false
    // R52-AP02: sign-out transition fence. Set synchronously in signOut()
    // before the async transition starts; cleared when persistLogoutThenReset
    // returns on every path, so it covers precommit, credential detachment,
    // failure recovery, and final publication.
    private var isSignOutTransitionActive = false
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var conflictMessage: String?
    private(set) var historyResolutionState: HistoryResolutionState = .none
    private(set) var isHistoryResolutionOfflineEscapeActive = false
    private(set) var localHistoryResolutionCount = 0
    private(set) var remoteHistoryResolutionCount = 0
    private(set) var needsPermissionIntroduction = false
    private(set) var replicationMode: ReplicationMode
    private(set) var irohStatus: IrohConnectionStatus = .stopped
    private(set) var roomInvite: String?
    private(set) var completionAlertTimerID: String?
    private(set) var isIrohRoomLeaveConfirmationPresented = false
    private(set) var isLeavingIrohRoom = false
    private(set) var snapshotLoadFailure: AppStatePersistenceCoordinator.SnapshotLoadFailure?
    private(set) var hasOversizedSavedSyncClaim = false
    var errorMessage: String?

    init(
        api: APIClient = APIClient(),
        defaults: UserDefaults = .standard,
        accountDeletionJournal: AccountDeletionJournal? = nil,
        durableLocalStore: AtomicDurableFileStore? = nil,
        roomStore: IrohRoomStore = IrohRoomStore(),
        endpointKeyStore: any IrohEndpointKeyStoring = IrohEndpointKeychainStore(),
        roomServiceFactory: (@MainActor @Sendable (RoomReplicationController.ServiceHandlers) -> any RoomReplicationServing)? = nil,
        alarmScheduler: (any TimerAlarmScheduling)? = nil,
        completionScheduler: TimerCompletionScheduler = TimerCompletionScheduler(),
        googleIdentityProvider: any GoogleIdentityProviding = SystemGoogleIdentityProvider(),
        retryDelay: Duration = .seconds(5),
        now: @escaping () -> Date = { .now },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore = { try SharedCore.bundled() }
    ) {
        let startup = Self.makeStartup(
            defaults: defaults, accountDeletionJournal: accountDeletionJournal,
            durableLocalStore: durableLocalStore, roomStore: roomStore,
            now: now, uptime: uptime, sharedCoreProvider: sharedCoreProvider)
        self.api = api
        self.defaults = defaults
        persistence = startup.persistence
        self.googleIdentityProvider = googleIdentityProvider
        self.accountDeletionJournal = startup.accountDeletionJournal
        self.roomStore = roomStore
        self.endpointKeyStore = endpointKeyStore
        self.roomServiceFactory = roomServiceFactory
        self.alarmScheduler = alarmScheduler ?? TimerAlarmScheduler()
        self.completionScheduler = completionScheduler
        self.retryDelay = retryDelay
        self.now = now
        self.uptime = uptime
        timerSessionController = startup.timerSessionController
        let coordinators = Self.makeCoordinators(
            api: api, googleIdentityProvider: googleIdentityProvider,
            sharedCoreProvider: sharedCoreProvider, startup: startup, roomStore: roomStore)
        workspaceMutationController = coordinators.workspaceMutationController
        accountSessionCoordinator = coordinators.accountSessionCoordinator
        alarmEffectCoordinator = coordinators.alarmEffectCoordinator
        taskIdentityCoreProvider = sharedCoreProvider
        replicationMode = startup.initialState.replicationMode
        timerState = startup.initialState.transition.state
        accountDeletionRecord = startup.accountDeletionRecovery.record
        accountDeletionPurgeState = startup.accountDeletionRecovery.purgeState
        physicalAnchor = startup.initialState.physicalAnchor
        needsPermissionIntroduction = startup.initialState.needsPermissionIntroduction
        restoreInitialState(startup.initialState.transition)
        watchSync.attach(self, defaults: defaults)
    }

    private static func makeStartup(
        defaults: UserDefaults,
        accountDeletionJournal: AccountDeletionJournal?,
        durableLocalStore: AtomicDurableFileStore?,
        roomStore: IrohRoomStore,
        now: () -> Date,
        uptime: () -> TimeInterval,
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore
    ) -> AppModelStartup {
        let usesProductionStorage = defaults === UserDefaults.standard
        let journal = accountDeletionJournal ?? (usesProductionStorage
            ? AccountDeletionJournal(fileURL: productionStorageURL("account-deletion-v1.json"))
            : nil)
        let localStore = durableLocalStore ?? (usesProductionStorage
            ? AtomicDurableFileStore(fileURL: productionStorageURL("timer-state-v2.json"))
            : nil)
        let timerController = TimerSessionController(sharedCoreProvider: sharedCoreProvider)
        let persistence = AppStatePersistenceCoordinator(
            defaults: defaults,
            durableLocalStore: localStore
        )
        return AppModelStartup(
            accountDeletionJournal: journal,
            timerSessionController: timerController,
            persistence: persistence,
            initialState: loadInitialState(
                defaults: defaults, roomStore: roomStore, persistence: persistence,
                now: now, uptime: uptime
            ),
            accountDeletionRecovery: loadAccountDeletionRecovery(
                journal: journal, defaults: defaults, roomStore: roomStore
            )
        )
    }

    private static func makeCoordinators(
        api: APIClient,
        googleIdentityProvider: any GoogleIdentityProviding,
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore,
        startup: AppModelStartup,
        roomStore: IrohRoomStore
    ) -> AppModelCoordinators {
        AppModelCoordinators(
            workspaceMutationController: SynchronizedWorkspaceMutationController(
                timerSessionController: startup.timerSessionController,
                sharedCoreProvider: sharedCoreProvider
            ),
            accountSessionCoordinator: makeAccountSessionCoordinator(
                api: api, googleIdentityProvider: googleIdentityProvider,
                sharedCoreProvider: sharedCoreProvider, persistence: startup.persistence,
                roomStore: roomStore, initialState: startup.initialState.transition.state
            ),
            alarmEffectCoordinator: AlarmEffectCoordinator(
                timerSessionController: startup.timerSessionController
            )
        )
    }

    private static func loadAccountDeletionRecovery(
        journal: AccountDeletionJournal?,
        defaults: UserDefaults,
        roomStore: IrohRoomStore
    ) -> AccountDeletionRecovery {
        let journalLoad: AccountDeletionJournal.LoadResult?
        if let journal {
            do {
                journalLoad = try journal.load()
            } catch {
                logger.error("loadAccountDeletionRecovery journal load failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
                journalLoad = .corrupt
            }
        } else {
            journalLoad = nil
        }
        switch journalLoad {
        case .record(let record):
            let purgeState: AccountDeletionPurgeState = record.phase == .prepared
                ? .prepared : .remoteCommitted
            return AccountDeletionRecovery(record: record, purgeState: purgeState)
        case .corrupt:
            let topology: AccountDeletionRoomTopology?
            do {
                topology = try roomStore.accountDeletionTopology()
            } catch {
                logger.error("loadAccountDeletionRecovery topology failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
                topology = nil
            }
            let record = AccountDeletionJournal.Record(
                phase: .prepared,
                roomIDs: topology?.roomIDs ?? [],
                roomSecretAccounts: topology?.roomSecretAccounts ?? []
            )
            return AccountDeletionRecovery(record: record, purgeState: .prepared)
        default:
            guard defaults.object(forKey: accountDeletionStateKey) != nil else {
                return AccountDeletionRecovery(record: nil, purgeState: nil)
            }
            let purgeState = defaults.string(forKey: accountDeletionStateKey)
                .flatMap(AccountDeletionPurgeState.init(rawValue:)) ?? .prepared
            return AccountDeletionRecovery(record: nil, purgeState: purgeState)
        }
    }

    private static func productionStorageURL(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomodorough", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func resetDefaultDurableStorage() {
        for name in ["account-deletion-v1.json", "timer-state-v2.json"] {
            do {
                try AtomicDurableFileStore(fileURL: productionStorageURL(name)).remove()
            } catch {
                // DEBUG UI-test reset only: outcome kept (reset continues),
                // Error-only capture (file error, never workspace content).
                logger.error("resetDefaultDurableStorage \(name, privacy: .public) failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
            }
        }
    }

    private static func loadInitialState(
        defaults: UserDefaults,
        roomStore: IrohRoomStore,
        persistence: AppStatePersistenceCoordinator,
        now: () -> Date,
        uptime: () -> TimeInterval
    ) -> InitialAppState {
        var mode = defaults.string(forKey: replicationModeKey)
            .flatMap(ReplicationMode.init(rawValue:)) ?? .centralized
        let wall = now()
        let elapsed = uptime()
        let anchor = WireBounds.physicalMilliseconds(for: wall) != nil
            && elapsed.isFinite && elapsed >= 0 ? (wall, elapsed) : nil
        let transition = persistence.load(
            replicationMode: mode, roomStore: roomStore,
            wallDate: wall, uptime: elapsed
        )
        if transition.replicationMode != mode {
            mode = transition.replicationMode
            defaults.set(ReplicationMode.offline.rawValue, forKey: replicationModeKey)
        }
#if os(iOS) || os(macOS)
        let introducesPermissions = !defaults.bool(forKey: permissionIntroductionKey)
#else
        let introducesPermissions = false
#endif
        return InitialAppState(
            transition: transition, replicationMode: mode,
            physicalAnchor: anchor, needsPermissionIntroduction: introducesPermissions
        )
    }

    private static func makeAccountSessionCoordinator(
        api: APIClient,
        googleIdentityProvider: any GoogleIdentityProviding,
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore,
        persistence: AppStatePersistenceCoordinator,
        roomStore: IrohRoomStore,
        initialState: PersistedTimerState
    ) -> CentralizedAccountSessionCoordinator {
        let historyResolution: AccountHistoryResolutionState
        if let request = initialState.pendingBootstrapResolution {
            historyResolution = .retryable(request.strategy)
        } else if initialState.bootstrapUser != nil {
            historyResolution = .retryable(nil)
        } else {
            historyResolution = .none
        }
        return CentralizedAccountSessionCoordinator(
            lifecycle: .init(api: api, googleIdentityProvider: googleIdentityProvider),
            synchronization: .init(api: api, sharedCoreProvider: sharedCoreProvider),
            initialPublication: .init(
                sessionState: .restoring,
                historyResolutionState: historyResolution
            ),
            persistence: persistence,
            roomStore: roomStore
        )
    }

    private func restoreInitialState(
        _ transition: AppStatePersistenceCoordinator.LoadTransition
    ) {
        snapshotLoadFailure = transition.snapshotLoadFailure
        guard snapshotLoadFailure == nil else { return }
        // Launch-time room bootstrap capture failure (AP53): the advanced
        // phase is kept, the capture error stays visible like a projection
        // error instead of dropping silently.
        if let message = transition.bootstrapCaptureError { errorMessage = message }
        guard accountDeletionPurgeState == nil else {
            quarantineAccountDeletion()
            return
        }
        applyCoordinatorPublication(accountSessionCoordinator.publication)
        let projectionSucceeded = rebuildOptimisticState()
        applyCoordinatorEffects(accountSessionCoordinator.loadCompletionEffects(
            for: transition,
            projectionSucceeded: projectionSucceeded
        ))
    }

    func retrySnapshotLoad() async {
        guard snapshotLoadFailure != nil else { return }
        let initialState = Self.loadInitialState(
            defaults: defaults, roomStore: roomStore, persistence: persistence,
            now: now, uptime: uptime
        )
        snapshotLoadFailure = initialState.transition.snapshotLoadFailure
        guard snapshotLoadFailure == nil else { return }
        timerState = initialState.transition.state
        replicationMode = initialState.replicationMode
        physicalAnchor = initialState.physicalAnchor
        accountSessionCoordinator = Self.makeAccountSessionCoordinator(
            api: api, googleIdentityProvider: googleIdentityProvider,
            sharedCoreProvider: taskIdentityCoreProvider, persistence: persistence, roomStore: roomStore,
            initialState: timerState
        )
        restoreInitialState(initialState.transition)
        setSceneActive(sceneIsActive)
        await restore()
    }

    deinit {
        alarmOperationTask?.cancel()
        timerCompletionTask?.cancel()
    }

    private func makeRoomReplicationController() -> RoomReplicationController {
        RoomReplicationController(
            mode: replicationMode,
            dependencies: makeRoomReplicationDependencies(),
            eventHandler: { [weak self] event in self?.applyRoomReplicationEvent(event) },
            operationHandler: { [weak self] operation in
                await self?.performRoomReplicationOperation(operation)
            }
        )
    }

    private func makeRoomReplicationDependencies() -> RoomReplicationController.Dependencies {
        RoomReplicationController.Dependencies(
            roomStore: roomStore,
            retryDelay: retryDelay,
            centralizedState: { [weak self] in
                self?.roomReplicationCentralizedState ?? RoomReplicationCentralizedState(
                    sessionGeneration: -1,
                    isSignedIn: false,
                    isWorkspaceMutationBlocked: true,
                    isSessionVerified: false,
                    localRevision: 0,
                    isSyncing: false,
                    isTimerActive: false,
                    isHistoryResolutionBlocking: false
                )
            },
            workspaceSnapshot: { [weak self] in
                guard let self else {
                    let state = PersistedTimerState.fresh()
                    return RoomReplicationWorkspaceSnapshot(
                        state: state,
                        genesis: Self.emptyIrohGenesis(from: state)
                    )
                }
                return RoomReplicationWorkspaceSnapshot(
                    state: self.timerState,
                    genesis: self.irohGenesis()
                )
            },
            revisionEvents: { [api] in try await api.revisionEvents() },
            sleep: { try await Task.sleep(for: $0) },
            secureRandomBytes: { RoomReplicationController.secureRandomBytes(count: $0) },
            encodeInvite: { roomID, roomName, endpointTicket, roomSecret in
                try IrohRoomInvite(
                    roomID: roomID,
                    roomName: roomName,
                    endpointTicket: endpointTicket,
                    roomSecret: roomSecret
                ).encoded()
            },
            makeService: { [roomStore, endpointKeyStore, roomServiceFactory] handlers in
                Self.makeRoomService(
                    handlers: handlers, roomStore: roomStore,
                    endpointKeyStore: endpointKeyStore, factory: roomServiceFactory
                )
            }
        )
    }

    private static func makeRoomService(
        handlers: RoomReplicationController.ServiceHandlers,
        roomStore: IrohRoomStore,
        endpointKeyStore: any IrohEndpointKeyStoring,
        factory: (@MainActor @Sendable (RoomReplicationController.ServiceHandlers) -> any RoomReplicationServing)?
    ) -> any RoomReplicationServing {
        if let factory { return factory(handlers) }
        return IrohReplicationService(
            store: roomStore,
            keyStore: endpointKeyStore,
            statusHandler: { handlers.status($0) },
            projectionHandler: { handlers.projection($0, $1) }
        )
    }

    private var roomReplicationCentralizedState: RoomReplicationCentralizedState {
        RoomReplicationCentralizedState(
            sessionGeneration: sessionGeneration,
            isSignedIn: isSignedIn,
            isWorkspaceMutationBlocked: isWorkspaceMutationBlocked,
            isSessionVerified: accountSessionCoordinator.isVerified(
                accountSessionCoordinator.currentOperation
            ),
            localRevision: timerState.revision,
            isSyncing: isSyncing,
            isTimerActive: isTimerActive,
            isHistoryResolutionBlocking: isHistoryResolutionBlocking
        )
    }

    private var roomReplicationEnvironment: RoomReplicationEnvironment {
        RoomReplicationEnvironment(
            deviceID: timerState.deviceId,
            displayName: nil,
            platform: Self.platform
        )
    }

    private var sessionGeneration: Int { accountSessionCoordinator.generation }

    private func applyRoomReplicationEvent(_ event: RoomReplicationEvent) {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        switch event {
        case .centralizedQuiesced:
            applyCoordinatorPublication(accountSessionCoordinator.quiesce())
        case .statusChanged(let status):
            irohStatus = status
        case .projectionReceived(let projection):
            applyRoomProjection(projection)
        }
    }

    private func performRoomReplicationOperation(_ operation: RoomReplicationOperation) async {
        guard accountDeletionPurgeState == nil else { return }
        switch operation {
        case .synchronize(let force, let showsActivity):
            await sync(force: force, showsActivity: showsActivity)
        case .unauthorized(let generation):
            await invalidateUnauthorizedSession(generation: generation)
        case .retry(let generation, let resolvesHistory):
            guard generation == sessionGeneration else { return }
            if resolvesHistory { await retryHistoryResolution() }
            else { await sync(force: true) }
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = sessionState { true } else { false }
    }

    var user: User? {
        if case .signedIn(let user) = sessionState { user } else { nil }
    }

    var selectedPhase: TimerPhase {
        get { timerState.settings.selectedPhase }
        set {
            _ = performWorkspaceMutation(.selectPhase(newValue))
        }
    }

    var selectedTaskID: UUID? {
        get { projectedSelectedTaskID }
        set {
            _ = performWorkspaceMutation(.selectTask(newValue))
        }
    }

    var autoStartBreaks: Bool {
        get { projectedAutoStartBreaks }
        set {
            _ = performWorkspaceMutation(.setAutoStartBreaks(newValue))
        }
    }

    var isTimerActive: Bool {
        canonicalTimer?.status == .running || canonicalTimer?.status == .paused
    }

    /// Background stale-alarm fix: backgrounded iOS runs no sync (streams
    /// cancelled on scene inactive), so a wake must sync before finishing.
    private var needsForegroundSync: Bool {
        guard !isWorkspaceMutationBlocked else { return false }
        if replicationMode == .offline { return false }
        if replicationMode == .iroh { return roomStore.activeSnapshot != nil }
        return isSignedIn || timerState.cachedUser != nil || timerState.bootstrapUser != nil
    }

    // Test seam for background stale-alarm regressions. DEBUG-only so the
    // production API does not widen for tests (AP121).
#if DEBUG
    var testForegroundSyncPending: Bool { foregroundSyncPending }
    var testNeedsForegroundSync: Bool { needsForegroundSync }
#endif

    var hasActiveCompletionAlert: Bool { completionAlertTimerID != nil }

    var activeTimer: CanonicalTimer? {
        if isTimerActive { return canonicalTimer }
        return durableIrohTimerNeedingCompletion
    }

    func elapsedForDisplay(_ timer: CanonicalTimer) -> TimeInterval {
        timer.elapsed(at: effectivePhysicalNow() ?? now())
    }

    func remainingForDisplay(_ timer: CanonicalTimer) -> TimeInterval {
        timer.remaining(at: effectivePhysicalNow() ?? now())
    }

    var pendingCommandCount: Int { timerState.pendingCommands.count }
    var pendingDurationOperationCount: Int { timerState.pendingDurationOperations.count }
    var pendingAutoStartOperationCount: Int { timerState.pendingAutoStartOperations.count }
    var pendingSelectedTaskOperationCount: Int { timerState.pendingSelectedTaskOperations.count }
    var pendingChangeCount: Int {
        pendingCommandCount
            + timerState.pendingTaskOperations.count
            + pendingDurationOperationCount
            + pendingAutoStartOperationCount
            + pendingSelectedTaskOperationCount
    }

    private func hasPendingSyncWork(_ state: PersistedTimerState) -> Bool {
        !state.pendingCommands.isEmpty
            || !state.pendingTaskOperations.isEmpty
            || !state.pendingDurationOperations.isEmpty
            || !state.pendingAutoStartOperations.isEmpty
            || !state.pendingSelectedTaskOperations.isEmpty
    }

    var activeRoom: IrohRoomSnapshot? {
        guard accountDeletionPurgeState == nil else { return nil }
        return roomStore.activeSnapshot
    }
    var preferredRoom: IrohRoomSnapshot? {
        guard accountDeletionPurgeState == nil else { return nil }
        return roomStore.preferredRoomID.flatMap(roomStore.roomSnapshot(roomID:))
    }
    var hasIrohRoom: Bool { preferredRoom != nil }
    var irohStatusLabel: String { irohStatus.label }
    var pendingAccountSwitchUser: User? { timerState.pendingAccountSwitchUser }
    var isWorkspaceMutationBlocked: Bool {
        snapshotLoadFailure != nil
            || accountDeletionPurgeState != nil
            || isHistoryResolutionBlocking
            || pendingAccountSwitchUser != nil
            || isSignOutTransitionActive
    }
    var hasPendingAccountDeletionRecovery: Bool { accountDeletionPurgeState != nil }
    /// Offline escape from failed history preflight (R43-AP05). Allowed only
    /// before any reconciliation is submitted: retryable without a strategy,
    /// offline, account recovery pending, no submitted request. Submitted
    /// reconciliation stays Retry-only so queued work cannot duplicate.
    var isHistoryResolutionOfflineEscapeAllowed: Bool {
        replicationMode == .centralized
            && historyResolutionState == .retryable(nil)
            && isOffline
            && timerState.bootstrapUser != nil
            && timerState.pendingBootstrapResolution == nil
    }
    var isHistoryResolutionBlocking: Bool {
        replicationMode == .centralized
            && !isHistoryResolutionOfflineEscapeActive
            && (historyResolutionState != .none
                || timerState.bootstrapUser != nil
                || timerState.pendingBootstrapResolution != nil)
    }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var completedFocusCountToday: Int {
        TimerSessionController.displayCompletedFocusCount(
            in: history,
            on: effectivePhysicalNow() ?? now()
        )
    }
    var longBreakProgress: Int {
        completedFocusCountToday == 0 ? 0 : ((completedFocusCountToday - 1) % 4) + 1
    }
    // Hex device suffix; localizedUppercase keeps hex casing locale-aware.
    var deviceMark: String { String(timerState.deviceId.suffix(4)).localizedUppercase }

    var syncLabel: String {
        if replicationMode == .iroh {
            if activeRoom?.conflict != nil { return String(localized: "Room repair needed") }
            return irohStatus.label
        }
        if replicationMode == .offline { return String(localized: "On device") }
        if !isSignedIn { return String(localized: "On device") }
        if isHistoryResolutionBlocking {
            switch historyResolutionState {
            case .preflighting: return String(localized: "Checking history")
            case .choosing, .confirming: return String(localized: "Choose history")
            case .submitting: return String(localized: "Resolving history")
            case .retryable: return String(localized: "History retry needed")
            case .none: break
            }
        }
        if conflictMessage != nil { return String(localized: "Review conflict") }
        if pendingChangeCount > 0 { return String(localized: "\(pendingChangeCount) queued") }
        if isOffline { return String(localized: "Offline") }
        if isSyncing { return String(localized: "Syncing") }
        return String(localized: "In sync")
    }

    func durationMinutes(for phase: TimerPhase) -> Int { timerState.settings.minutes(for: phase) }

    // R52-AP03: current workspace epoch for deferred Watch settings. Created
    // once and persisted, so a restart keeps the epoch and same-workspace
    // retries stay accepted; rotated at ownership changes, so deferred
    // settings from a previous workspace are rejected as stale.
    private var watchWorkspaceGeneration: UUID {
        if let raw = defaults.string(forKey: Self.watchWorkspaceGenerationKey),
           let existing = UUID(uuidString: raw) { return existing }
        let created = UUID()
        defaults.set(created.uuidString, forKey: Self.watchWorkspaceGenerationKey)
        return created
    }

    private func rotateWatchWorkspaceGeneration() {
        defaults.set(UUID().uuidString, forKey: Self.watchWorkspaceGenerationKey)
    }

    func makeWatchSnapshot() -> WatchTimerSnapshot {
        let settings = timerState.settings
        let nowDate = now()
        if let timer = activeTimer {
            let status: String
            switch timer.status {
            case .running: status = "running"
            case .paused: status = "paused"
            default: status = "idle"
            }
            return WatchTimerSnapshot(
                phase: timer.phase.rawValue,
                status: status,
                timerId: timer.id,
                workspaceGeneration: watchWorkspaceGeneration,
                timerRevision: WatchTimerRevision(
                    timerId: timer.id,
                    intentId: timer.lastIntent?.commandId,
                    phase: timer.phase.rawValue,
                    status: timer.status.rawValue,
                    plannedDurationMs: timer.plannedDurationMs,
                    elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                    anchorAt: timer.anchorAt
                ),
                plannedDurationMs: timer.plannedDurationMs,
                elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                anchorAt: timer.anchorAt,
                selectedPhase: settings.selectedPhase.rawValue,
                focusDurationMs: settings.durationsMs.focus,
                shortBreakDurationMs: settings.durationsMs.shortBreak,
                longBreakDurationMs: settings.durationsMs.longBreak,
                updatedAt: nowDate
            )
        }
        let selected = settings.selectedPhase
        let planned = settings.durationsMs.durationMs(for: selected)
        return WatchTimerSnapshot(
            phase: selected.rawValue,
            status: "idle",
            workspaceGeneration: watchWorkspaceGeneration,
            plannedDurationMs: planned,
            elapsedAtAnchorMs: 0,
            anchorAt: nowDate,
            selectedPhase: selected.rawValue,
            focusDurationMs: settings.durationsMs.focus,
            shortBreakDurationMs: settings.durationsMs.shortBreak,
            longBreakDurationMs: settings.durationsMs.longBreak,
            updatedAt: nowDate
        )
    }

    /// Rejects stale timer controls so the caller can push a fresh snapshot.
    @discardableResult
    func applyWatchCommand(_ command: WatchTimerCommand, isDeferred: Bool = false) -> Bool {
        guard !isDeferred || command.allowsDeferredDelivery else { return false }
        switch command.name {
        case "start":
            return applyWatchStartCommand()
        case "pause":
            guard isWatchCommandTargetCurrent(command), activeTimer?.status == .running else { return false }
            guard pause() else {
                reportWatchPauseRefusal()
                return false
            }
            return true
        case "resume":
            return applyWatchResumeCommand(command)
        case "finish":
            return applyWatchFinishCommand(command)
        case "selectPhase":
            guard isWatchSettingsWorkspaceCurrent(command, isDeferred: isDeferred) else { return false }
            guard let raw = command.phase, let phase = TimerPhase(rawValue: raw) else { return false }
            return selectPhase(phase)
        case "setDuration":
            guard isWatchSettingsWorkspaceCurrent(command, isDeferred: isDeferred) else { return false }
            guard let raw = command.phase, let phase = TimerPhase(rawValue: raw),
                  let minutes = command.minutes else { return false }
            return setDurationMinutes(minutes, for: phase)
        default:
            reportWatchUnknownCommand(nameCount: command.name.count)
            return false
        }
    }

    private func reportWatchUnknownCommand(nameCount: Int) {
        let diagnostic = WatchUnknownCommandError(nameLength: nameCount)
        if WatchSyncLogDedupe.shouldLog(key: "watch-command-unknown") {
            Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        }
        SentryCapture.captureOnce(key: "watch-command-unknown", error: diagnostic)
    }

    /// Revision comparison also rejects replays after a successful mutation,
    /// including after relaunch, without relying on the Watch's clock.
    private func isWatchCommandTargetCurrent(_ command: WatchTimerCommand) -> Bool {
        guard let target = command.timerId,
              let expected = command.expectedTimerRevision,
              activeTimer?.id == target else { return false }
        return makeWatchSnapshot().timerRevision == expected
    }

    // R52-AP03: deferred settings must prove their workspace epoch. A queued
    // setting from a previous workspace (or a legacy command with no epoch)
    // is rejected with a corrective push instead of mutating the new
    // workspace. Live legacy commands stay accepted so older watch apps keep
    // working while connected; a live command carrying a mismatched epoch is
    // still stale and rejected. Never uses sentAt, the Watch clock, or the
    // timer revision to identify an idle workspace.
    private func isWatchSettingsWorkspaceCurrent(
        _ command: WatchTimerCommand,
        isDeferred: Bool
    ) -> Bool {
        if let offered = command.workspaceGeneration {
            guard offered == watchWorkspaceGeneration else {
                reportWatchStaleWorkspace()
                return false
            }
            return true
        }
        guard !isDeferred else {
            reportWatchStaleWorkspace()
            return false
        }
        return true
    }

    private func reportWatchStaleWorkspace() {
        let diagnostic = WatchStaleWorkspaceError()
        if WatchSyncLogDedupe.shouldLog(key: "watch-command-stale-workspace") {
            Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        }
        SentryCapture.captureOnce(key: "watch-command-stale-workspace", error: diagnostic)
    }

    private func reportWatchPauseRefusal() {
        Self.logger.error("watch pause refused")
        SentryCapture.captureOnce(key: "watch-command-pause-refused", error: WatchPauseRefusedError())
        if errorMessage == nil {
            errorMessage = String(localized: "Watch Pause not applied.")
        }
    }

    private func applyWatchStartCommand() -> Bool {
        guard start() else {
            reportWatchStartRefusal()
            return false
        }
        return true
    }

    private func applyWatchResumeCommand(_ command: WatchTimerCommand) -> Bool {
        guard isWatchCommandTargetCurrent(command), activeTimer?.status == .paused else { return false }
        guard resume() else {
            reportWatchResumeRefusal()
            return false
        }
        return true
    }

    private func applyWatchFinishCommand(_ command: WatchTimerCommand) -> Bool {
        guard isWatchCommandTargetCurrent(command) else { return false }
        guard finish() else {
            reportWatchFinishRefusal()
            return false
        }
        return true
    }

    private func reportWatchStartRefusal() {
        Self.logger.error("watch start refused")
        SentryCapture.captureOnce(key: "watch-command-start-refused", error: WatchStartRefusedError())
        if errorMessage == nil {
            errorMessage = String(localized: "Watch Start not applied.")
        }
    }

    private func reportWatchResumeRefusal() {
        Self.logger.error("watch resume refused")
        SentryCapture.captureOnce(key: "watch-command-resume-refused", error: WatchResumeRefusedError())
        if errorMessage == nil {
            errorMessage = String(localized: "Watch Resume not applied.")
        }
    }

    private func reportWatchFinishRefusal() {
        Self.logger.error("watch finish refused")
        SentryCapture.captureOnce(key: "watch-command-finish-refused", error: WatchFinishRefusedError())
        if errorMessage == nil {
            errorMessage = String(localized: "Watch Finish not applied.")
        }
    }

    @discardableResult
    func selectPhase(_ phase: TimerPhase) -> Bool {
        performWorkspaceMutation(.selectPhase(phase))
    }

    @discardableResult
    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) -> Bool {
        performWorkspaceMutation(.setDurationMinutes(minutes, for: phase))
    }

    @discardableResult
    func addTask(_ title: String) async -> Bool {
        guard !isWorkspaceMutationBlocked else {
            refuseWorkspaceMutationDuringSignOut()
            return false
        }
        let task: FocusTask
        do {
            let core = try taskIdentityCore ?? taskIdentityCoreProvider()
            taskIdentityCore = core
            task = try core.dispatch(
                "task.identity.v1",
                inputJSON: JSONEncoder.api.encode(["title": title]),
                as: FocusTask.self
            )
            guard task.isValid else {
                throw SharedCoreError.invalidResponse("task identity is inconsistent")
            }
        } catch {
            Self.logger.error("addTask failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            errorMessage = error.localizedDescription
            return false
        }
        guard !tasks.contains(where: { $0.id == task.id }) else { return true }
        return enqueueTaskOperation(.upsert, task: task)
    }

    func deleteTask(id: UUID) {
        guard !isWorkspaceMutationBlocked else {
            refuseWorkspaceMutationDuringSignOut()
            return
        }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        _ = enqueueTaskOperation(.delete, task: task)
    }

    func task(forTimerID timerID: String) -> FocusTask? {
        statePublisher.task(forTimerID: timerID, snapshot: publicationSnapshot)
    }

    func displayTask(for timer: CanonicalTimer) -> FocusTask? {
        statePublisher.displayTask(for: timer, snapshot: publicationSnapshot)
    }

    /// Title of the selected focus task, whatever phase is running.
    /// `displayTask` is nil for breaks by design; the widget needs the
    /// selection itself. Falls back to known tasks when the projection has
    /// not converged the selection yet.
    func selectedTaskTitle() -> String? {
        guard let id = selectedTaskID else { return nil }
        let snapshot = publicationSnapshot
        return snapshot.tasks.first(where: { $0.id == id })?.title
            ?? snapshot.state.knownTasks.first(where: { $0.id == id })?.title
    }

    func taskSummaries(for date: Date = .now, calendar: Calendar = .current) -> [TaskDailySummary] {
        statePublisher.taskSummaries(
            for: date,
            calendar: calendar,
            snapshot: publicationSnapshot
        )
    }

    func dayFocusTotals(for date: Date = .now, calendar: Calendar = .current) -> (finishedPomodoros: Int, timeSpentMs: Int64) {
        statePublisher.dayFocusTotals(
            for: date,
            calendar: calendar,
            snapshot: publicationSnapshot
        )
    }

    func completedFocusSummaries() -> [CompletedFocusSummary] {
        statePublisher.completedFocusSummaries(snapshot: publicationSnapshot)
    }

    func taskContext(for item: HistoryItem) -> String {
        statePublisher.taskContext(for: item, snapshot: publicationSnapshot)
    }

    private var publicationSnapshot: AppStatePublisher.Snapshot {
        AppStatePublisher.Snapshot(
            canonicalTimer: canonicalTimer,
            history: history,
            tasks: tasks,
            state: timerState
        )
    }

    func restore() async {
        guard snapshotLoadFailure == nil else { return }
        if accountDeletionPurgeState != nil {
            await resumeAccountDeletion()
            return
        }
        guard sessionState == .restoring else { return }
        let transition = await accountSessionCoordinator.restore(
            cachedUser: timerState.cachedUser ?? timerState.bootstrapUser
        )
        switch applyCoordinatorTransition(transition) {
        case .ignored, .localOnly:
            return
        case .verify(let operation):
            await verifyRestoredSession(operation: operation)
        case .unauthorized(let operation):
            await invalidateUnauthorizedSession(operation: operation)
        }
    }

    func allowTimerAlerts() async {
        do {
            try await alarmScheduler.requestAuthorization()
        } catch {
            Self.logger.error("allowTimerAlerts failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
        }
        completePermissionIntroduction()
    }

    func skipTimerAlertPermissions() {
        completePermissionIntroduction()
    }

    func signIn() {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else {
            errorMessage = String(localized: "Finish account deletion cleanup before signing in.")
            return
        }
        let transition = accountSessionCoordinator.beginSignIn(
            isWorking: isWorking
        )
        guard case .started(let operation) = applyCoordinatorTransition(transition) else {
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            defer {
                if accountSessionCoordinator.owns(operation) { isWorking = false }
            }
            let authentication = await accountSessionCoordinator.authenticate(
                operation,
                deviceID: timerState.deviceId,
                platform: Self.platform
            )
            switch applyCoordinatorTransition(authentication) {
            case .stale:
                return
            case .authenticated(let user, let operation):
                await completeAuthenticatedSession(
                    user: user,
                    operation: operation
                )
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    func confirmAccountSwitch() async {
        guard let proposed = accountSessionCoordinator.confirmAccountSwitch(
            state: timerState,
            authenticatedUser: user
        ) else { return }
        // R50-AP01: commit previous/proposed atomically. Install the
        // switched projection and alarm only after durable success.
        let previous = timerState
        let previousTimer = canonicalTimer
        let saved = accountSessionCoordinator.persistAtomically(
            previous: previous,
            proposed: proposed,
            to: .local,
            rebuildsOnRollback: false
        )
        guard applyPersistenceTransition(saved) else {
            reportAccountSwitchPersistFailure()
            errorMessage = String(localized: "Account switch paused because local data could not be saved.")
            return
        }
        applyCoordinatorPublication(accountSessionCoordinator.finishConfirmedAccountSwitch())
        rebuildOptimisticState()
        // R52-AP03: confirmed switch starts a new workspace epoch so deferred
        // Watch settings from the previous account are rejected as stale.
        rotateWatchWorkspaceGeneration()
        reconcileAlarm(
            from: previousTimer,
            to: activeTimer,
            at: effectivePhysicalNow() ?? now()
        )
        await sync(force: true)
    }

    private func reportAccountSwitchPersistFailure() {
        let quarantined = snapshotLoadFailure != nil
        let outcome: AccountSwitchConfirmDiagnostics.Outcome =
            quarantined ? .uncertain : .failed
        let diagnostic = AccountSwitchConfirmDiagnostics(
            outcome: outcome,
            quarantined: quarantined,
            pendingOperations: pendingChangeCount
        )
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    func cancelAccountSwitch() async {
        guard timerState.pendingAccountSwitchUser != nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        if let failure = await accountSessionCoordinator.logout() {
            errorMessage = failure
            reportAccountSwitchCancelFailure(stage: .credentials)
            return
        }
        var proposed = timerState
        proposed.pendingAccountSwitchUser = nil
        let previous = timerState
        let saved = accountSessionCoordinator.persistAtomically(
            previous: previous,
            proposed: proposed,
            to: persistenceDestination(for: proposed),
            rebuildsOnRollback: true
        )
        guard applyPersistenceTransition(saved) else {
            reportAccountSwitchCancelFailure(stage: .persist)
            errorMessage = String(localized: "Account switch cancellation paused because local data could not be saved.")
            return
        }
        guard let transition = accountSessionCoordinator.beginAccountSwitchCancellation(
            hasPendingAccountSwitch: true, isWorking: false
        ) else { return }
        applyAccountReset(transition)
        errorMessage = nil
    }

    private func reportAccountSwitchCancelFailure(stage: AccountSwitchCancelDiagnostics.Stage) {
        let quarantined = snapshotLoadFailure != nil
        let outcome: AccountSwitchCancelDiagnostics.Outcome = quarantined ? .uncertain : .failed
        let diagnostic = AccountSwitchCancelDiagnostics(
            stage: stage,
            outcome: outcome,
            quarantined: quarantined,
            pendingOperations: pendingChangeCount
        )
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    func signOut() {
        guard snapshotLoadFailure == nil, !isWorking else { return }
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        isWorking = true
        isSignOutTransitionActive = true
        Task {
            await persistLogoutThenReset(
                preservesBootstrapResolution: preservesBootstrapResolution
            )
        }
    }

    private func persistLogoutThenReset(
        preservesBootstrapResolution: Bool
    ) async {
        defer {
            isSignOutTransitionActive = false
            isWorking = false
        }
        errorMessage = nil
        guard prepareSignedOutReturnState(preservesBootstrapResolution: preservesBootstrapResolution) else {
            return
        }
        await quiesceCentralizedSyncForSignOut()
        let previous = timerState
        let proposal = signedOutProposal(preservesBootstrapResolution: preservesBootstrapResolution)
        guard precommitSignedOutSnapshot(previous: previous, proposed: proposal.state) else {
            return
        }
        if let failure = await accountSessionCoordinator.logout() {
            restoreAccountSnapshotAfterDetachFailure()
            reportSignOutFailure(stage: .credentials)
            errorMessage = failure
            return
        }
        finishSignedOutPublication(
            preservesBootstrapResolution: preservesBootstrapResolution,
            proposal: proposal,
            previousTimerID: canonicalTimer?.id
        )
    }

    private func signedOutProposal(
        preservesBootstrapResolution: Bool
    ) -> AccountLifecycleController.SignedOutStorageTransition {
        accountSessionCoordinator.signedOutStorageTransition(
            state: timerState,
            replicationMode: replicationMode,
            preservesBootstrapResolution: preservesBootstrapResolution,
            activeReturnState: roomStore.activeReturnState
        )
    }

    private func precommitSignedOutSnapshot(
        previous: PersistedTimerState,
        proposed: PersistedTimerState
    ) -> Bool {
        let precommit = accountSessionCoordinator.persistAtomically(
            previous: previous,
            proposed: proposed,
            to: persistenceDestination(for: proposed),
            rebuildsOnRollback: true
        )
        guard precommit.action.succeeded else {
            _ = applyPersistenceTransition(precommit)
            reportSignOutFailure(stage: replicationMode == .iroh ? .roomSnapshot : .snapshot)
            errorMessage = String(localized: "Sign-out paused because local data could not be saved.")
            return false
        }
        return true
    }

    private func restoreAccountSnapshotAfterDetachFailure() {
        guard persist() else {
            reportSignOutFailure(stage: .snapshot)
            return
        }
    }

    private func reportSignOutFailure(stage: SignOutDiagnostics.Stage) {
        let quarantined = snapshotLoadFailure != nil
        let outcome: SignOutDiagnostics.Outcome = quarantined ? .uncertain : .failed
        let diagnostic = SignOutDiagnostics(
            stage: stage,
            outcome: outcome,
            quarantined: quarantined,
            pendingOperations: pendingChangeCount
        )
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    // R52-AP02: reports a domain mutation refused while the sign-out
    // transition owns the workspace. Bounded pending count only.
    private func refuseWorkspaceMutationDuringSignOut() {
        guard isSignOutTransitionActive else { return }
        let diagnostic = SignOutMutationRefusedDiagnostics(pendingOperations: pendingChangeCount)
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
        if errorMessage == nil {
            errorMessage = String(localized: "Sign-out is in progress. Changes are paused until it finishes.")
        }
    }

    private func quiesceCentralizedSyncForSignOut() async {
        roomReplicationController.cancelCentralizedStreams()
        applyCoordinatorPublication(accountSessionCoordinator.quiesce())
        let task = centralizedSyncTask
        task?.cancel()
        _ = await task?.value
    }

    private func finishSignedOutPublication(
        preservesBootstrapResolution: Bool,
        proposal: AccountLifecycleController.SignedOutStorageTransition,
        previousTimerID: String?
    ) {
        guard let transition = accountSessionCoordinator.beginSignOut(
            isWorking: false,
            preservesBootstrapResolution: preservesBootstrapResolution,
            pendingStrategy: timerState.pendingBootstrapResolution?.strategy
        ) else {
            reportSignOutFailure(stage: .publish)
            errorMessage = String(localized: "Sign-out paused because local data could not be saved.")
            watchSync.push()
            return
        }
        applyAccountReset(transition)
        timerState = proposal.state
        if proposal.rebuildsProjection { rebuildOptimisticState() }
        if !preservesBootstrapResolution, let timerID = previousTimerID {
            cancelAlarm(timerID: timerID)
        }
        guard persist() else {
            reportSignOutFailure(stage: .publish)
            errorMessage = String(localized: "Sign-out paused because local data could not be saved.")
            watchSync.push()
            return
        }
        // R52-AP03: signed-out workspace starts a new epoch so deferred Watch
        // settings queued before sign-out are rejected instead of mutating it.
        rotateWatchWorkspaceGeneration()
        errorMessage = nil
        watchSync.push()
    }

    private func applyAccountReset(
        _ transition: CentralizedAccountSessionCoordinator.Transition<
            CentralizedAccountSessionCoordinator.ResetAction
        >
    ) {
        applyCoordinatorPublication(transition.publication)
        if let working = transition.action.isWorking { isWorking = working }
        applyCoordinatorEffects(transition.effects)
    }

    private func prepareSignedOutReturnState(preservesBootstrapResolution: Bool) -> Bool {
        let transition = accountSessionCoordinator.signedOutStorageTransition(
            state: timerState,
            replicationMode: replicationMode,
            preservesBootstrapResolution: preservesBootstrapResolution,
            activeReturnState: roomStore.activeReturnState
        )
        if let returnState = transition.irohReturnState {
            guard precommitSignedOutLocalFallback(returnState) else { return false }
            do {
                try roomStore.replaceActiveReturnState(returnState)
            } catch {
                reportSignOutFailure(stage: .roomSnapshot)
                Self.logger.error("prepareSignedOutReturnState return-state failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.captureOnce(key: "sign-out-return-state", error: error)
                errorMessage = String(localized: "Sign-out paused because its recovery state could not be saved.")
                return false
            }
        }
        return true
    }

    private func precommitSignedOutLocalFallback(_ state: PersistedTimerState) -> Bool {
        // The local snapshot remains reachable when room secrets are unavailable.
        // Commit the safe return workspace without installing it over the shared room.
        let saved = persistence.persist(state, to: .local)
        guard saved.succeeded else {
            snapshotLoadFailure = persistence.snapshotLoadFailure
            if snapshotLoadFailure != nil {
                roomReplicationController.cancelRetry()
                roomReplicationController.cancelCentralizedStreams()
            }
            reportSignOutFailure(stage: .localSnapshot)
            errorMessage = String(localized: "Sign-out paused because local data could not be saved.")
            return false
        }
        return true
    }

    func deleteAccount(confirmation: String) async {
        guard confirmation == "DELETE", isSignedIn, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let topology: AccountDeletionRoomTopology?
        do {
            topology = try roomStore.accountDeletionTopology()
        } catch {
            Self.logger.error("deleteAccount topology failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            topology = nil
        }
        guard let topology,
              persistPreparedAccountDeletion(topology: topology) else {
            errorMessage = String(localized: "Account deletion paused because its recovery state could not be saved.")
            return
        }
        await roomReplicationController.quiesceForAccountDeletion()
        await quiesceCentralizedSyncForAccountDeletion()
        switch await accountSessionCoordinator.deleteAccount(confirmation: confirmation) {
        case .rejected(let message):
            guard clearAccountDeletionState() else {
                quarantineAccountDeletion()
                errorMessage = String(localized: "Account deletion was rejected, but its recovery state could not be cleared.")
                return
            }
            let rollback = await roomReplicationController.rollbackAccountDeletion(
                environment: roomReplicationEnvironment
            )
            if rollback == .synchronize { await sync(force: true) }
            errorMessage = message
            return
        case .unknown:
            quarantineAccountDeletion()
            errorMessage = String(localized: "Account deletion is waiting to confirm the remote result.")
            return
        case .committed:
            quarantineAccountDeletion()
        }
        guard persistAccountDeletionState(.remoteCommitted) else {
            errorMessage = String(localized: "Account deletion was confirmed, but local cleanup is waiting for durable recovery state.")
            return
        }
        await finishConfirmedAccountDeletion()
    }

    private func resumeAccountDeletion() async {
        quarantineAccountDeletion()
        await roomReplicationController.quiesceForAccountDeletion()
        await quiesceCentralizedSyncForAccountDeletion()
        if accountDeletionPurgeState == .prepared {
            let discovered: AccountDeletionRoomTopology
            do {
                discovered = try roomStore.accountDeletionTopology()
            } catch {
                Self.logger.error("resumeAccountDeletion topology failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
                errorMessage = String(localized: "Account deletion paused because its recovery state could not be saved.")
                return
            }
            let retained = AccountDeletionRoomTopology(
                roomIDs: (accountDeletionRecord?.roomIDs ?? []) + discovered.roomIDs,
                roomSecretAccounts: (accountDeletionRecord?.roomSecretAccounts ?? [])
                    + discovered.roomSecretAccounts
            )
            guard persistPreparedAccountDeletion(topology: retained) else {
                errorMessage = String(localized: "Account deletion paused because its recovery state could not be saved.")
                return
            }
            guard await accountSessionCoordinator.restoreAccountDeletionCredentials() else {
                errorMessage = String(localized: "Account deletion is waiting for retained credentials.")
                return
            }
            guard case .committed = await accountSessionCoordinator.deleteAccount(
                confirmation: "DELETE"
            ) else {
                errorMessage = String(localized: "Account deletion is waiting to confirm the remote result.")
                return
            }
            guard persistAccountDeletionState(.remoteCommitted) else { return }
        }
        await finishConfirmedAccountDeletion()
    }

    func retryAccountDeletionRecovery() async {
        guard accountDeletionPurgeState != nil, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        await resumeAccountDeletion()
    }

    // Internal (not private) so SentryCaptureTests drives the real
    // purge path instead of calling SentryCapture directly.
    func finishConfirmedAccountDeletion() async {
        guard let retainedRoomIDs = accountDeletionRoomIDs(),
              let retainedAccounts = accountDeletionRoomSecretAccounts() else {
            quarantineAccountDeletion()
            errorMessage = String(localized: "Account data was removed; use Retry account deletion to continue room cleanup.")
            return
        }
        let credentialsCleared = await accountSessionCoordinator.clearTokens()
        timerState = .fresh()
        rebuildOptimisticState()
        guard persistLocalAccountPurge() else {
            quarantineAccountDeletion()
            errorMessage = String(localized: "Account deletion was confirmed; use Retry account deletion to continue local cleanup.")
            return
        }
        do {
            try roomStore.purgeAccountData(
                retainedRoomIDs: retainedRoomIDs,
                roomSecretAccounts: retainedAccounts
            )
        } catch {
            Self.logger.error("purgeAccountData failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            quarantineAccountDeletion()
            errorMessage = String(localized: "Account deletion was confirmed; use Retry account deletion to continue room cleanup.")
            return
        }
        guard credentialsCleared else {
            errorMessage = String(localized: "Account data was removed; use Retry account deletion to continue credential cleanup.")
            return
        }
        guard completeAccountDeletionOfflineReset() else { return }
    }

    // Tail of finishConfirmedAccountDeletion (AP58): durably select Offline
    // and release deletion state. Each durable-write failure is logged +
    // captured once (AP59) and leaves a localized retry message.
    private func completeAccountDeletionOfflineReset() -> Bool {
        defaults.set(ReplicationMode.offline.rawValue, forKey: Self.replicationModeKey)
        guard defaults.string(forKey: Self.replicationModeKey) == ReplicationMode.offline.rawValue else {
            Self.logger.error("completeAccountDeletionOfflineReset replication-mode write failed")
            SentryCapture.captureOnce(key: "account-deletion-offline-mode", error: AccountDeletionDurableWriteError(step: "replication-mode"))
            errorMessage = String(localized: "Local cleanup completed; use Retry account deletion to continue recovery-state cleanup.")
            return false
        }
        guard clearAccountDeletionRoomIDs() else {
            Self.logger.error("completeAccountDeletionOfflineReset room-ids clear failed")
            SentryCapture.captureOnce(key: "account-deletion-room-ids", error: AccountDeletionDurableWriteError(step: "room-ids"))
            errorMessage = String(localized: "Account data was removed; use Retry account deletion to continue room cleanup.")
            return false
        }
        replicationMode = .offline
        roomInvite = nil
        isIrohRoomLeaveConfirmationPresented = false
        irohStatus = .stopped
        rebuildOptimisticState()
        guard clearAccountDeletionState() else {
            Self.logger.error("completeAccountDeletionOfflineReset deletion-state clear failed")
            SentryCapture.captureOnce(key: "account-deletion-state", error: AccountDeletionDurableWriteError(step: "deletion-state"))
            errorMessage = String(localized: "Local cleanup completed; use Retry account deletion to continue recovery-state cleanup.")
            return false
        }
        roomReplicationController.completeAccountDeletion()
        return true
    }

    private func quarantineAccountDeletion() {
        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id)
        }
        applyAccountReset(accountSessionCoordinator.completeDeletion())
        timerState = .fresh()
        canonicalTimer = nil
        history = []
        tasks = []
        completionAlertTimerID = nil
        // R52-AP03: deleted account's workspace epoch ends here.
        rotateWatchWorkspaceGeneration()
        watchSync.push()
    }

    private func persistPreparedAccountDeletion(
        topology: AccountDeletionRoomTopology
    ) -> Bool {
        if let accountDeletionJournal {
            let record = AccountDeletionJournal.Record(
                phase: .prepared,
                roomIDs: topology.roomIDs,
                roomSecretAccounts: topology.roomSecretAccounts
            )
            let result = reconcileJournalSave(record, journal: accountDeletionJournal)
            switch result.outcome {
            case .applied(let observed):
                accountDeletionRecord = observed
                accountDeletionPurgeState = observed.phase == .remoteCommitted
                    ? .remoteCommitted : .prepared
                if !result.completedWithoutError { quarantineAccountDeletion() }
                return result.completedWithoutError && observed.phase == .prepared
            case .unknown:
                accountDeletionRecord = record
                accountDeletionPurgeState = .prepared
                quarantineAccountDeletion()
                return false
            case .notApplied:
                return false
            }
        }
        guard persistAccountDeletionRoomIDs(topology.roomIDs),
              persistAccountDeletionState(.prepared) else {
            _ = clearAccountDeletionRoomIDs()
            return false
        }
        return true
    }

    private enum JournalSaveOutcome {
        case applied(AccountDeletionJournal.Record)
        case notApplied
        case unknown
    }

    private func reconcileJournalSave(
        _ record: AccountDeletionJournal.Record,
        journal: AccountDeletionJournal
    ) -> (outcome: JournalSaveOutcome, completedWithoutError: Bool) {
        let prior: AccountDeletionJournal.LoadResult
        do {
            prior = try journal.load()
        } catch {
            Self.logger.error("reconcileJournalSave load failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            return (.unknown, false)
        }
        if case .record(let priorRecord) = prior,
           priorRecord.phase == .remoteCommitted,
           record.phase == .prepared {
            return (.applied(priorRecord), true)
        }
        let completedWithoutError: Bool
        do {
            try journal.save(record)
            completedWithoutError = true
        } catch {
            Self.logger.error("reconcileJournalSave failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            completedWithoutError = false
        }
        let current: AccountDeletionJournal.LoadResult
        do {
            current = try journal.load()
        } catch {
            Self.logger.error("reconcileJournalSave verify-load failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            return (.unknown, completedWithoutError)
        }
        if case .record(let observed) = current,
           observed.phase == .remoteCommitted {
            return (.applied(observed), completedWithoutError)
        }
        if current == .record(record) { return (.applied(record), completedWithoutError) }
        if current == prior { return (.notApplied, completedWithoutError) }
        return (.unknown, completedWithoutError)
    }

    private func persistAccountDeletionState(_ state: AccountDeletionPurgeState) -> Bool {
        if let accountDeletionJournal {
            guard let current = accountDeletionRecord else { return false }
            let phase: AccountDeletionJournal.Phase = state == .prepared
                ? .prepared : .remoteCommitted
            let record = AccountDeletionJournal.Record(
                phase: phase,
                roomIDs: current.roomIDs,
                roomSecretAccounts: current.roomSecretAccounts
            )
            let result = reconcileJournalSave(record, journal: accountDeletionJournal)
            guard case .applied(let observed) = result.outcome,
                  observed.phase == .remoteCommitted else { return false }
            accountDeletionRecord = observed
            accountDeletionPurgeState = .remoteCommitted
            return true
        }
        defaults.set(state.rawValue, forKey: Self.accountDeletionStateKey)
        guard defaults.string(forKey: Self.accountDeletionStateKey) == state.rawValue else {
            return false
        }
        accountDeletionPurgeState = state
        return true
    }

    // Internal (not private) so SentryCaptureTests drives the real
    // clear path instead of calling SentryCapture directly.
    func clearAccountDeletionState() -> Bool {
        if let accountDeletionJournal {
            do {
                try accountDeletionJournal.clear()
                guard try accountDeletionJournal.load() == .absent else { return false }
                accountDeletionRecord = nil
                accountDeletionPurgeState = nil
                return true
            } catch {
                Self.logger.error("clearAccountDeletionState failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
                return false
            }
        }
        defaults.removeObject(forKey: Self.accountDeletionStateKey)
        guard defaults.object(forKey: Self.accountDeletionStateKey) == nil else { return false }
        accountDeletionPurgeState = nil
        return true
    }

    private func persistAccountDeletionRoomIDs(_ roomIDs: [String]) -> Bool {
        let data: Data
        do {
            data = try JSONEncoder().encode(roomIDs.sorted())
        } catch {
            Self.logger.error("persistAccountDeletionRoomIDs encode failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            return false
        }
        defaults.set(data, forKey: Self.accountDeletionRoomIDsKey)
        return defaults.data(forKey: Self.accountDeletionRoomIDsKey) == data
    }

    private func accountDeletionRoomIDs() -> [String]? {
        if accountDeletionJournal != nil { return accountDeletionRecord?.roomIDs }
        guard let data = defaults.data(forKey: Self.accountDeletionRoomIDsKey) else { return nil }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            Self.logger.error("accountDeletionRoomIDs decode failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            return nil
        }
    }

    private func accountDeletionRoomSecretAccounts() -> [String]? {
        if accountDeletionJournal != nil { return accountDeletionRecord?.roomSecretAccounts }
        return accountDeletionRoomIDs()?.map { "room-secret-v1.\($0)" }
    }

    private func clearAccountDeletionRoomIDs() -> Bool {
        if accountDeletionJournal != nil { return true }
        defaults.removeObject(forKey: Self.accountDeletionRoomIDsKey)
        return defaults.object(forKey: Self.accountDeletionRoomIDsKey) == nil
    }

    private func persistLocalAccountPurge() -> Bool {
        applyPersistenceTransition(accountSessionCoordinator.persist(
            timerState,
            to: .local
        ))
    }

    @discardableResult
    func handleGoogleSignInURL(_ url: URL) -> Bool {
        accountSessionCoordinator.handleGoogleSignInURL(url)
    }

    @discardableResult
    func start() -> Bool {
        performWorkspaceMutation(.startTimer)
    }

    @discardableResult
    func pause(at explicitDate: Date? = nil) -> Bool {
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        return performWorkspaceMutation(.pauseTimer(at: date))
    }

    @discardableResult
    func resume(at explicitDate: Date? = nil) -> Bool {
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        return performWorkspaceMutation(.resumeTimer(at: date))
    }

    /// Widget deep-link entry point: mirrors the main Start/Pause/Resume button.
    func toggleTimer() {
        switch canonicalTimer?.status {
        case .running:
            pause()
        case .paused:
            resume()
        default:
            start()
        }
    }

    @discardableResult
    func finish(at explicitDate: Date? = nil) -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
        if foregroundSyncPending, needsForegroundSync {
            // AP120: no sync result exists yet, so the copy must not claim
            // another device changed the timer — only that a sync gates finish.
            errorMessage = String(localized: "Syncing latest state before finish.")
            return false
        }
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        return finish(at: date, cancelsAlarm: true)
    }

    @discardableResult
    private func finish(
        at date: Date,
        cancelsAlarm: Bool,
        timer explicitTimer: CanonicalTimer? = nil,
        automatic: Bool = false
    ) -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
        if foregroundSyncPending, needsForegroundSync { return false }
        guard let timer = explicitTimer ?? canonicalTimer,
              timer.status == .running || timer.status == .paused else { return false }
        let localDate = effectivePhysicalNow() ?? now()
        do {
            let occurredAt = try trustedOccurrenceDate(localDate: localDate)
            let plan = try alarmEffectCoordinator.finishPlan(.init(
                timer: timer,
                completionDate: date,
                occurredAt: occurredAt,
                localDate: localDate,
                state: timerState,
                replicationMode: replicationMode,
                physicalNow: localDate,
                autoStartsBreak: autoStartBreaks,
                automatic: automatic
            ))
            return commitFinishPlan(
                plan,
                timer: timer,
                cancelsAlarm: cancelsAlarm
            )
        } catch {
            reportFinishPlanFailure(error)
            return false
        }
    }

    private func commitFinishPlan(
        _ plan: AlarmEffectCoordinator.FinishPlan,
        timer: CanonicalTimer,
        cancelsAlarm: Bool
    ) -> Bool {
        switch plan {
        case .ignored:
            return false
        case .finish(let preparation):
            return commitFinishedTimer(
                preparation.state,
                timer: timer,
                commandID: preparation.command.id,
                cancelsAlarm: cancelsAlarm
            )
        case .irohBreak(let automaticBreak, let preparation):
            return startIrohBreak(
                automaticBreak,
                after: timer,
                preparation: preparation,
                cancelsAlarm: cancelsAlarm
            )
        case .centralizedBreak(let automaticBreak, let preparation):
            return startCentralizedBreak(
                automaticBreak,
                after: timer,
                preparation: preparation,
                cancelsAlarm: cancelsAlarm
            )
        }
    }

    private func commitFinishedTimer(
        _ state: PersistedTimerState,
        timer: CanonicalTimer,
        commandID: String,
        cancelsAlarm: Bool
    ) -> Bool {
        guard commitSynchronizedState(
            state,
            requiringTimerCommandIDs: [commandID]
        ) else { return false }
        if cancelsAlarm {
            cancelAlarm(timerID: timer.id)
        }
        return true
    }

    private func startIrohBreak(
        _ automaticBreak: TimerSessionController.AutomaticBreak,
        after timer: CanonicalTimer,
        preparation: TimerSessionController.FinishTransition,
        cancelsAlarm: Bool
    ) -> Bool {
        let finishID = preparation.command.id
        guard commitSynchronizedState(
                  preparation.state,
                  requiringTimerCommandIDs: [finishID]
              ),
              history.contains(where: { $0.commandId == finishID && $0.status == "completed" }),
              enqueue(
                  .start,
                  timerID: automaticBreak.timerID,
                  taskID: nil,
                  phase: automaticBreak.phase,
                  duration: automaticBreak.duration,
                  elapsed: 0
              ) else { return false }
        scheduleAutomaticBreak(automaticBreak, after: timer, cancelsAlarm: cancelsAlarm)
        return true
    }

    private func startCentralizedBreak(
        _ automaticBreak: TimerSessionController.AutomaticBreak,
        after timer: CanonicalTimer,
        preparation: TimerSessionController.FinishTransition,
        cancelsAlarm: Bool
    ) -> Bool {
        let transition: TimerSessionController.AutomaticBreakTransition
        do {
            transition = try timerSessionController.prepareCentralizedAutomaticBreak(
                automaticBreak,
                after: timer,
                finish: preparation
            )
        } catch {
            reportCentralizedBreakFailure(error)
            return false
        }
        guard commitSynchronizedState(
            transition.state,
            requiringTimerCommandIDs: [preparation.command.id, transition.command.id]
        ) else { return false }
        scheduleAutomaticBreak(automaticBreak, after: timer, cancelsAlarm: cancelsAlarm)
        return true
    }

    private func scheduleAutomaticBreak(
        _ automaticBreak: TimerSessionController.AutomaticBreak,
        after timer: CanonicalTimer,
        cancelsAlarm: Bool
    ) {
        executeAlarmPlan(timerSessionController.automaticBreakAlarmPlan(
            automaticBreak,
            replacing: timer.id,
            cancelsPreviousAlarm: cancelsAlarm
        ))
    }

    func cancel(at explicitDate: Date? = nil) {
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        _ = performWorkspaceMutation(.cancelTimer(at: date))
    }

    // AP92: retained although TimerControls no longer offers Dismiss.
    // Finished timers land on Skip and the next Start replaces them
    // (see startReplacesTerminalTimer), so this stays only as the
    // tested planClear API for clearing a terminal timer directly.
    func clear() {
        _ = performWorkspaceMutation(.clearTimer)
    }

    func stopSound() {
        CompletionChimePlayer.shared.stop()
        guard let alertTimerID = completionAlertTimerID else { return }
        completionAlertTimerID = nil
        cancelAlarm(timerID: alertTimerID)
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard !isWorkspaceMutationBlocked else { return }
        // Background stale-alarm fix: a fired-but-unacked OS alarm must not
        // finish from a stale snapshot when sync is pending after background.
        guard !foregroundSyncPending || !needsForegroundSync else { return }
        guard let timer = durableIrohTimerNeedingCompletion ?? canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              completionQueuedFor != timer.id else { return }
        // Fire-time canonical revalidation: drop stale finish when paused or
        // when canonical remaining is still positive post-sync.
        guard timer.remaining(at: date) <= 0 else { return }
        if replicationMode == .iroh {
            completeIrohTimerIfNeeded(timer, at: date)
            return
        }
        if finish(at: date, cancelsAlarm: false, timer: timer, automatic: true) {
            noteCompletionAlert(timerID: timer.id)
            stopCompletionAlertIfTimerStarted()
            completionQueuedFor = canonicalTimer?.status == .running ? timer.id : nil
        } else {
            retryAutomaticCompletion(timer: timer, at: date)
        }
    }

    private func retryAutomaticCompletion(timer: CanonicalTimer, at date: Date) {
        guard timerForCompletionDeadline()?.id == timer.id,
              timer.remaining(at: date) <= 0,
              conflictMessage != nil || errorMessage != nil else { return }
        cancelTimerCompletion()
        scheduleTimerCompletion(minimumDelay: 5)
    }

    // Internal (not private) so SentryCaptureTests drives the real
    // iroh-completion path instead of calling SentryCapture directly.
    func completeIrohTimerIfNeeded(_ timer: CanonicalTimer, at date: Date) {
        let physicalNow = effectivePhysicalNow() ?? now()
        do {
            guard let plan = try alarmEffectCoordinator.irohCompletionPlan(
                timer: timer,
                at: date,
                state: timerState,
                replicationMode: replicationMode,
                physicalNow: physicalNow,
                autoStartsBreak: autoStartBreaks
            ) else { return }
            switch plan {
            case .persist(let state, let timerID):
                persistCompletedIrohTimer(state, timerID: timerID)
            case .automaticBreak(let state, let timer, let completedAt, let nextPhase):
                startAutomaticIrohBreak(
                    after: timer,
                    completedAt: completedAt,
                    nextPhase: nextPhase,
                    state: state
                )
            }
        } catch {
            Self.logger.error("completeIrohTimerIfNeeded failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            errorMessage = error.localizedDescription
            retryAutomaticCompletion(timer: timer, at: date)
        }
    }

    private func persistCompletedIrohTimer(_ state: PersistedTimerState, timerID: String) {
        timerState = state
        rebuildOptimisticState()
        guard persist() else {
            guard timerForCompletionDeadline()?.id == timerID else { return }
            cancelTimerCompletion()
            scheduleTimerCompletion(minimumDelay: 5)
            return
        }
        noteCompletionAlert(timerID: timerID)
        stopCompletionAlertIfTimerStarted()
        watchSync.push()
    }

    private func startAutomaticIrohBreak(
        after timer: CanonicalTimer,
        completedAt: Date?,
        nextPhase: TimerPhase,
        state: PersistedTimerState
    ) {
        guard let completedAt else { return }
        let preparation: TimerSessionController.AutomaticBreakTransition?
        do {
            let localDate = effectivePhysicalNow() ?? now()
            let occurredAt = try trustedOccurrenceDate(localDate: localDate)
            preparation = try timerSessionController.prepareIrohAutomaticBreak(
                completedAt: completedAt,
                nextPhase: nextPhase,
                occurredAt: occurredAt,
                localDate: localDate,
                state: state
            )
        } catch {
            reportIrohBreakFailure(error)
            return
        }
        guard let preparation else { return }
        guard commitSynchronizedState(
            preparation.state,
            requiringTimerCommandIDs: [preparation.command.id]
        ) else {
            guard timerForCompletionDeadline()?.id == timer.id else { return }
            cancelTimerCompletion()
            scheduleTimerCompletion(minimumDelay: 5)
            return
        }
        noteCompletionAlert(timerID: timer.id)
        stopCompletionAlertIfTimerStarted()
        scheduleAlarm(for: preparation.automaticBreak)
    }

    private func scheduleAlarm(for automaticBreak: TimerSessionController.AutomaticBreak) {
        executeAlarmPlan(timerSessionController.alarmPlan(for: .schedule(
            timerID: automaticBreak.timerID,
            phase: automaticBreak.phase,
            duration: automaticBreak.duration
        )))
    }

    func completeIfNeeded(timerID: String) {
        guard let date = effectivePhysicalNow() else { return }
        completeIfNeeded(timerID: timerID, at: date)
    }

    private func cancelTimerCompletion() {
        timerCompletionTask?.cancel()
        timerCompletionTask = nil
        scheduledCompletionTimer = nil
    }

    private func timerForCompletionDeadline() -> CanonicalTimer? {
        guard let timer = durableIrohTimerNeedingCompletion else { return canonicalTimer }
        do {
            return try timerState.physicalCanonicalTimer(timer)
        } catch {
            reportCompletionDeadlineFailure(error)
            return nil
        }
    }

    private func scheduleTimerCompletion(minimumDelay: TimeInterval = 0) {
        guard timerCompletionSuspensions == 0, !isWorkspaceMutationBlocked,
              let timer = timerForCompletionDeadline(),
              timer.status == .running,
              completionQueuedFor != timer.id,
              let date = effectivePhysicalNow() else {
            cancelTimerCompletion()
            return
        }
        guard scheduledCompletionTimer != timer else { return }
        cancelTimerCompletion()
        scheduledCompletionTimer = timer
        let delay = max(minimumDelay, timer.remaining(at: date))
        timerCompletionTask = completionScheduler.schedule(after: delay) { [weak self] in
            self?.timerCompletionDeadlineFired(timerID: timer.id)
        }
    }

    private func timerCompletionDeadlineFired(timerID: String) {
        completeIfNeeded(timerID: timerID)
        guard let timer = timerForCompletionDeadline(),
              timer.id == timerID, timer.status == .running,
              let date = effectivePhysicalNow(), timer.remaining(at: date) > 0 else { return }
        cancelTimerCompletion()
        scheduleTimerCompletion()
    }

    private func reconcileTimerCompletion() {
        cancelTimerCompletion()
        scheduleTimerCompletion()
        guard let timer = scheduledCompletionTimer,
              let date = effectivePhysicalNow(), timer.remaining(at: date) <= 0 else { return }
        timerCompletionTask?.cancel()
        timerCompletionDeadlineFired(timerID: timer.id)
    }

    private func suspendTimerCompletion() {
        timerCompletionSuspensions += 1
        cancelTimerCompletion()
    }

    private func resumeTimerCompletion() {
        timerCompletionSuspensions -= 1
        scheduleTimerCompletion()
    }

    func waitForAlarmOperations() async {
        await alarmOperationTask?.value
    }

    func dismissConflict() { conflictMessage = nil }

    func requestHistoryResolution(_ strategy: BootstrapResolutionStrategy) {
        applyCoordinatorPublication(
            accountSessionCoordinator.requestHistoryResolution(strategy)
        )
    }

    func cancelHistoryResolutionConfirmation() {
        applyCoordinatorPublication(
            accountSessionCoordinator.cancelHistoryResolutionConfirmation()
        )
    }

    /// Dismisses the blocking sheet to reach the local timer while offline.
    /// Persisted recovery (bootstrapUser, queues, submitted request) is
    /// untouched; relaunch re-blocks until the next retry succeeds.
    func continueHistoryResolutionOffline() {
        guard isHistoryResolutionOfflineEscapeAllowed else { return }
        isHistoryResolutionOfflineEscapeActive = true
    }

    func returnToHistoryResolution() {
        isHistoryResolutionOfflineEscapeActive = false
    }

    func confirmHistoryResolution() async {
        guard let (strategy, snapshot) = accountSessionCoordinator.confirmedHistoryResolution()
        else { return }
        await submitBootstrapResolution(strategy: strategy, snapshot: snapshot)
    }

    func retryHistoryResolution() async {
        guard case .retryable = historyResolutionState else { return }
        switch accountSessionCoordinator.bootstrapRetryAction(
            pendingRequest: timerState.pendingBootstrapResolution
        ) {
        case .signIn:
            signIn()
        case .verify(let operation):
            await verifyRestoredSession(operation: operation)
        case .submit(let request, let operation):
            await submitPersistedBootstrapResolution(
                request,
                generation: operation.generation
            )
        case .preflight(let operation):
            await preflightBootstrapResolution(generation: operation.generation)
        }
    }

    @discardableResult
    func sync(force: Bool = false, showsActivity: Bool = true) async -> Bool {
        guard snapshotLoadFailure == nil else { return false }
        let start = accountSessionCoordinator.beginSync(
            workspace: centralizedWorkspace,
            force: force,
            showsActivity: showsActivity
        )
        switch applyCoordinatorTransition(start) {
        case .ignored, .coalesced:
            return false
        case .verify(let operation):
            await verifyRestoredSession(operation: operation)
            return false
        case .invalidPendingOperations:
            return false
        case .started(let lease):
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return false }
                return await self.runSync(lease)
            }
            centralizedSyncTaskID = taskID
            centralizedSyncTask = task
            return await withTaskCancellationHandler {
                let installed = await task.value
                if centralizedSyncTaskID == taskID {
                    centralizedSyncTask = nil
                    centralizedSyncTaskID = nil
                }
                return installed
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func quiesceCentralizedSyncForAccountDeletion() async {
        roomReplicationController.cancelCentralizedStreams()
        applyCoordinatorPublication(accountSessionCoordinator.quiesce())
        let task = centralizedSyncTask
        task?.cancel()
        _ = await task?.value
    }

    private func runSync(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async -> Bool {
        var allowsFollowUpSync = true
        var installed = false
        defer {
            finishSync(lease, allowsFollowUp: allowsFollowUpSync)
        }
        do {
            installed = try await performSync(lease)
        } catch {
            allowsFollowUpSync = await handleSyncFailure(error, lease: lease)
            installed = false
        }
        return installed
    }

    private func finishSync(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease,
        allowsFollowUp: Bool
    ) {
        let hintedFollowUp = accountSessionCoordinator.ownsSyncLease(lease)
            && roomReplicationController.consumeRevisionFollowUp()
        let finish = accountSessionCoordinator.finishSync(
            lease,
            workspace: centralizedWorkspace,
            hintedFollowUp: hintedFollowUp,
            allowsFollowUp: allowsFollowUp
        )
        if applyCoordinatorTransition(finish) == .synchronize {
            Task { [weak self] in await self?.sync(force: true) }
        }
    }

    private func performSync(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async throws -> Bool {
        var installed = false
        repeat {
            guard try await performSyncRound(lease) else { return installed }
            installed = true
        } while centralizedWorkspace.hasPendingOperations
        _ = applyCoordinatorTransition(accountSessionCoordinator.finishSyncRounds(
            lease,
            workspace: centralizedWorkspace
        ))
        return installed
    }

    private func performSyncRound(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async throws -> Bool {
        // R50-L03: preparation failures never reach the delivery-stage
        // report below. Record malformed plans at pre-send with counts
        // and Core provenance; expected limit/dependency outcomes stay
        // quiet and keep the coordinator presentation-only shape.
        let prepared: (plan: AccountSynchronization.SyncPlan, retired: PersistedTimerState)
        do {
            prepared = try accountSessionCoordinator.prepareSyncPlan(state: timerState)
        } catch {
            if let batch = error as? SyncBatchPlanError, batch.isInvalidResponse {
                reportSyncBoundaryFailure(error, stage: .preSend, rollback: .notEligible)
            }
            throw error
        }
        let plan = prepared.plan
        if plan.legacyDependencyReviewRequired { throw LegacyTimerDependencyReview.required }
        if plan.coreStatus == "blocked_dependency" { throw SyncBatchPlanError.blockedSync }
        if plan.batch.isEmpty, hasPendingSyncWork(timerState) {
            throw AppError.invalidResponse
        }
        let preSendPrevious = timerState
        timerState = prepared.retired
        guard persistAtomically(previous: preSendPrevious, rebuildsOnRollback: true) else {
            throw AppError.invalidResponse
        }
        let attempt = SyncDeliveryAttempt()
        do {
            return try await sendReconcileAndCommit(plan, lease: lease, attempt: attempt)
        } catch {
            let rollback = restorePreSendClaim(
                error, previous: preSendPrevious, retired: prepared.retired, stage: attempt.stage
            )
            reportSyncBoundaryFailure(error, stage: attempt.stage, rollback: rollback)
            throw error
        }
    }

    private func selectedTaskProjectionAfterRetirement() throws -> CoreProjectionOutput? {
        guard !timerState.pendingSelectedTaskOperations.isEmpty else { return nil }
        return try project(timerState)
    }

    private func sendReconcileAndCommit(
        _ plan: AccountSynchronization.SyncPlan,
        lease: CentralizedAccountSessionCoordinator.SyncLease,
        attempt: SyncDeliveryAttempt
    ) async throws -> Bool {
        let previousTimer = activeTimer
        let retiredProjection = try selectedTaskProjectionAfterRetirement()
        let sampledResponse = try await accountSessionCoordinator.sendSync(plan, state: timerState) {
            attempt.stage = .possibleDelivery
            if let retiredProjection {
                projectedSelectedTaskID = retiredProjection.selectedTaskId.flatMap(UUID.init(uuidString:))
            }
        }
        let receivedAt = effectivePhysicalNow() ?? now()
        guard accountSessionCoordinator.ownsCentralizedReplication(
            lease.operation,
            modeGeneration: lease.modeGeneration,
            workspace: centralizedWorkspace
        ) else { return false }
        attempt.stage = .reconciliation
        let transition = try accountSessionCoordinator.reconcileSync(
            sampledResponse,
            plan: plan,
            state: timerState
        )
        if let message = transition.conflictMessage { conflictMessage = message }
        attempt.stage = .commit
        try commitSyncedState(transition.state, previousTimer: previousTimer, receivedAt: receivedAt)
        return true
    }

    private func restorePreSendClaim(
        _ error: Error,
        previous: PersistedTimerState,
        retired: PersistedTimerState,
        stage: SyncFailureDiagnostics.Stage
    ) -> SyncFailureDiagnostics.Rollback {
        guard stage == .preSend else { return .deliveryPossible }
        guard shouldRestorePreSendClaim(for: error) else { return .notEligible }
        // Restore only the exact snapshot whose metadata this unsent attempt retired.
        guard timerState == retired else { return .snapshotChanged }
        timerState = previous
        return persistAtomically(previous: retired, rebuildsOnRollback: false)
            ? .restored : .persistenceFailed
    }

    private func reportSyncBoundaryFailure(
        _ error: Error, stage: SyncFailureDiagnostics.Stage, rollback: SyncFailureDiagnostics.Rollback
    ) {
        let diagnostic = SyncFailureDiagnostics(error: error, stage: stage, rollback: rollback, state: timerState)
        guard syncFailureDiagnosticBudget.record(diagnostic) else { return }
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        guard diagnostic.warrantsCapture else { return }
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    private func shouldRestorePreSendClaim(for error: Error) -> Bool {
        if error as? AppError == .invalidResponse { return true }
        if error as? AppError == .invalidLocalClock { return true }
        if error is SharedCoreError { return true }
        if let batch = error as? SyncBatchPlanError {
            if case .invalidResponse = batch { return true }
        }
        return false
    }

    @discardableResult
    func recoverOversizedSavedSyncClaim(confirmed: Bool) -> Bool {
        guard snapshotLoadFailure == nil, !isWorking else { return false }
        let previous = timerState
        do {
            timerState = try accountSessionCoordinator.discardSavedSyncClaim(
                confirmed: confirmed, state: timerState
            )
            guard persistAtomically(previous: previous, rebuildsOnRollback: false) else { return false }
            hasOversizedSavedSyncClaim = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func commitSyncedState(
        _ state: PersistedTimerState,
        previousTimer: CanonicalTimer?,
        receivedAt: Date
    ) throws {
        let projection = try project(state)
        let previousState = timerState
        let publication = prepareWorkspacePublication(state: state, output: projection)
        timerState = publication?.state ?? state
        pruneLocalTimerOwners()
        // Atomic rollback restores the persist layer's authoritative
        // state; presentation below runs only after commit.
        guard persistAtomically(previous: previousState, rebuildsOnRollback: false) else {
            throw AppError.invalidResponse
        }
        installPreparedPublication(publication)
        reconcileAlarm(from: previousTimer, to: activeTimer, at: receivedAt)
        applyCoordinatorPublication(accountSessionCoordinator.markSyncSucceeded())
        errorMessage = nil
        foregroundSyncPending = false
    }

    private func handleSyncFailure(
        _ error: Error,
        lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async -> Bool {
        if error as? SyncBatchPlanError == .oversizedSaved { hasOversizedSavedSyncClaim = true }
        let failure = accountSessionCoordinator.syncFailure(
            error,
            lease: lease,
            workspace: centralizedWorkspace,
            pendingChangeCount: pendingChangeCount
        )
        switch applyCoordinatorTransition(failure) {
        case .stale, .schedulesRetry:
            return true
        case .unauthorized(let operation):
            await invalidateUnauthorizedSession(operation: operation)
            return true
        case .blocksFollowUp:
            return false
        }
    }

    private var isExplicitForegroundGateReleaseAllowed: Bool {
        replicationMode == .offline
    }

    private func clearForegroundSyncGate() {
        foregroundSyncPending = false
        completionQueuedFor = nil
    }

    func refreshAfterForeground() async {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        guard needsForegroundSync else {
            clearForegroundSyncGate()
            reconcileTimerCompletion()
            let action = await roomReplicationController.refreshAfterForeground(
                environment: roomReplicationEnvironment
            )
            if action == .synchronize { _ = await sync(force: true) }
            return
        }
        let action = await roomReplicationController.refreshAfterForeground(
            environment: roomReplicationEnvironment
        )
        switch action {
        case .synchronize:
            let installed = await sync(force: true)
            guard installed || isExplicitForegroundGateReleaseAllowed else { return }
            clearForegroundSyncGate()
            reconcileTimerCompletion()
        case .irohRefreshed(let roomID, let modeGeneration):
            guard releaseIrohForegroundGate(roomID: roomID, modeGeneration: modeGeneration) else {
                reportIrohForegroundRefresh(outcome: .retained)
                return
            }
            reportIrohForegroundRefresh(outcome: .released)
        case .none:
            if isExplicitForegroundGateReleaseAllowed {
                clearForegroundSyncGate()
                reconcileTimerCompletion()
            }
        }
    }

    // R50-AP03: room-fenced Iroh release. Backend-owner check only;
    // never clears the centralized stale-completion gate.
    private func releaseIrohForegroundGate(roomID: String, modeGeneration: Int) -> Bool {
        guard replicationMode == .iroh,
            roomReplicationController.modeGeneration == modeGeneration,
            roomStore.activeSnapshot?.roomID == roomID,
            roomStore.activeSnapshot?.conflict == nil
        else { return false }
        clearForegroundSyncGate()
        reconcileTimerCompletion()
        return true
    }

    private func reportIrohForegroundRefresh(outcome: IrohForegroundRefreshDiagnostics.Outcome) {
        let diagnostic = IrohForegroundRefreshDiagnostics(outcome: outcome)
        Self.logger.info("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        guard outcome == .retained else { return }
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    /// S1 OOM relief (POMODOROUGH-37): drops cached WasmKit runtimes after
    /// a memory warning. Next sync/identity operation lazily reloads them;
    /// in-flight operations hold their own references and are unaffected.
    func releaseMemoryPressure() {
        taskIdentityCore?.releaseRuntimeForMemoryPressure()
        taskIdentityCore = nil
        accountSessionCoordinator.releaseMemoryPressure()
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        if !active {
            foregroundSyncPending = true
        } else if foregroundSyncPending, needsForegroundSync {
            cancelTimerCompletion()
            scheduleTimerCompletion()
        } else {
            reconcileTimerCompletion()
        }
        roomReplicationController.setSceneActive(active, environment: roomReplicationEnvironment)
    }

    func setReplicationMode(_ mode: ReplicationMode) async {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        guard mode != replicationMode else {
            if mode == .iroh {
                roomReplicationController.scheduleIrohStartup(environment: roomReplicationEnvironment)
            }
            return
        }
        errorMessage = nil
        roomInvite = nil
        suspendTimerCompletion()
        let transition = await roomReplicationController.changeMode(
            to: mode,
            environment: roomReplicationEnvironment
        )
        resumeTimerCompletion()
        guard case .modeChanged(let target, let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return
        }
        replicationMode = target
        defaults.set(target.rawValue, forKey: Self.replicationModeKey)
        adoptRoomWorkspace(state)
        guard persist() else {
            errorMessage = conflictMessage
            return
        }
        if target == .centralized, let user {
            await completeAuthenticatedSession(
                user: user,
                operation: accountSessionCoordinator.currentOperation
            )
        } else if target == .iroh {
            roomReplicationController.scheduleIrohStartup(environment: roomReplicationEnvironment)
        }
    }

    func createIrohRoom(name rawName: String) async -> Bool {
        guard snapshotLoadFailure == nil else { return false }
        guard accountDeletionPurgeState == nil else { return false }
        suspendTimerCompletion()
        let transition = await roomReplicationController.createRoom(
            name: rawName,
            environment: roomReplicationEnvironment
        )
        resumeTimerCompletion()
        guard case .roomCreated(let state, let invite, let status) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return false
        }
        replicationMode = .iroh
        defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
        adoptRoomWorkspace(state)
        roomInvite = invite
        irohStatus = status
        errorMessage = nil
        return true
    }

    private func irohGenesis() -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: canonicalTimer,
            history: history,
            tasks: tasks,
            durationsMs: timerState.canonicalDurations(),
            autoStartBreaks: autoStartBreaks,
            selectedTaskId: selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter
        )
    }

    private static func emptyIrohGenesis(from state: PersistedTimerState) -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: state.canonicalTimer,
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.canonicalDurations(),
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.canonicalSelectedTaskID?.uuidString.lowercased(),
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
    }

    func refreshIrohInvite() async {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        let transition = await roomReplicationController.refreshInvite(
            environment: roomReplicationEnvironment
        )
        if case .inviteRefreshed(let invite) = transition { roomInvite = invite }
        if case .failed(let message) = transition { errorMessage = message }
    }

    func joinIrohRoom(inviteText: String) async -> Bool {
        guard snapshotLoadFailure == nil else { return false }
        guard accountDeletionPurgeState == nil else { return false }
        suspendTimerCompletion()
        let transition = await roomReplicationController.joinRoom(
            inviteText: inviteText,
            environment: roomReplicationEnvironment
        )
        resumeTimerCompletion()
        guard case .roomJoined(let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return false
        }
        replicationMode = .iroh
        defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
        adoptRoomWorkspace(state)
        roomInvite = nil
        errorMessage = nil
        return true
    }

    func requestIrohRoomLeave() {
        guard accountDeletionPurgeState == nil else { return }
        guard replicationMode == .iroh, !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = true
    }

    func cancelIrohRoomLeave() {
        guard !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = false
    }

    func confirmIrohRoomLeave() async {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        guard replicationMode == .iroh,
              isIrohRoomLeaveConfirmationPresented,
              !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = false
        isLeavingIrohRoom = true
        suspendTimerCompletion()
        defer { isLeavingIrohRoom = false }
        let transition = await roomReplicationController.leaveRoom(
            environment: roomReplicationEnvironment
        )
        resumeTimerCompletion()
        guard case .roomLeft(let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return
        }
        replicationMode = .offline
        defaults.set(ReplicationMode.offline.rawValue, forKey: Self.replicationModeKey)
        roomInvite = nil
        adoptRoomWorkspace(state)
        guard persist() else {
            errorMessage = conflictMessage
            return
        }
    }

    func syncIrohNow() async {
        guard snapshotLoadFailure == nil else { return }
        guard accountDeletionPurgeState == nil else { return }
        await roomReplicationController.syncIroh(environment: roomReplicationEnvironment)
    }

    func refreshForPull(showsActivity: Bool = true) async {
        if replicationMode == .iroh {
            await syncIrohNow()
        } else {
            await sync(force: true, showsActivity: showsActivity)
        }
    }

    private var centralizedWorkspace: CentralizedAccountSessionCoordinator.Workspace {
        CentralizedAccountSessionCoordinator.Workspace(
            state: timerState,
            replicationMode: replicationMode,
            modeGeneration: roomReplicationController.modeGeneration,
            isMutationBlocked: isWorkspaceMutationBlocked
        )
    }

    func nextBreakPhase() -> TimerPhase {
        do {
            let core = try taskIdentityCore ?? taskIdentityCoreProvider()
            taskIdentityCore = core
            return try TimerSessionController.phaseAfterFocus(
                history: history,
                on: effectivePhysicalNow() ?? now(),
                core: core
            )
        } catch {
            Self.logger.error("nextBreakPhase fallback: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            return timerState.settings.selectedPhase
        }
    }

    /// Idle skip returns breaks to focus; focus uses the existing cycle destination.
    var skipDestination: TimerPhase {
        selectedPhase.isBreak ? .focus : skipDestinationFromFocus()
    }

    /// Skip offers a long break after 3, 7, 11, ... completed focuses today.
    func skipDestinationFromFocus() -> TimerPhase {
        completedFocusCountToday % 4 == 3 ? .longBreak : .shortBreak
    }

    private func enqueue(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) -> Bool {
        performWorkspaceMutation(.command(.init(
            type: type,
            timerID: timerID,
            taskID: taskID,
            phase: phase,
            duration: duration,
            elapsed: elapsed
        )))
    }

    private func mutationSnapshot() -> SynchronizedWorkspaceMutationController.Snapshot {
        SynchronizedWorkspaceMutationController.Snapshot(
            state: timerState,
            canonicalTimer: canonicalTimer,
            tasks: tasks,
            projectedAutoStartBreaks: projectedAutoStartBreaks,
            projectedSelectedTaskID: projectedSelectedTaskID,
            replicationMode: replicationMode,
            localDate: effectivePhysicalNow() ?? now(),
            trustedClockUptime: uptime(),
            isWorkspaceMutationBlocked: isWorkspaceMutationBlocked
        )
    }

    @discardableResult
    private func performWorkspaceMutation(
        _ intent: SynchronizedWorkspaceMutationController.Intent
    ) -> Bool {
        do {
            guard let transition = try workspaceMutationController.plan(
                intent,
                from: mutationSnapshot()
            ) else {
                refuseWorkspaceMutationDuringSignOut()
                return false
            }
            let applied = applyWorkspaceMutation(transition)
            if applied { watchSync.push() }
            return applied
        } catch AppError.invalidLocalClock {
            reportInvalidLocalClock()
            return false
        } catch let admission as WorkspaceIntentAdmissionError {
            reportAdmissionFailure(admission)
            return false
        } catch {
            Self.logger.error("performWorkspaceMutation failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func reportAdmissionFailure(_ admission: WorkspaceIntentAdmissionError) {
        switch admission {
        case .coreRejected(let diagnostics):
            Self.logger.error("workspace mutation rejected: \(diagnostics.publicMessage(), privacy: .public)")
            SentryCapture.capture(admission)
            errorMessage = diagnostics.publicMessage()
        case .invalidCoreResponse(let diagnostics):
            Self.logger.error("workspace mutation invalid Core: \(diagnostics.publicMessage(), privacy: .public)")
            SentryCapture.capture(admission)
            errorMessage = diagnostics.publicMessage()
        case .ignoredRetarget(let diagnostics):
            Self.logger.error("workspace retarget ignored: \(diagnostics.publicMessage(), privacy: .public)")
            SentryCapture.capture(admission)
        }
    }

    private func prepareWorkspacePublication(
        state: PersistedTimerState,
        output: CoreProjectionOutput?
    ) -> AppStatePublisher.Publication? {
        guard let output else { return nil }
        return statePublisher.publication(
            output: output,
            state: state,
            completionAlertTimerID: completionAlertTimerID,
            completionQueuedFor: completionQueuedFor
        )
    }

    private func commitMutationDurableWrite(previous: PersistedTimerState) -> Bool {
        persistAtomically(previous: previous, rebuildsOnRollback: false)
    }

    private func installPreparedPublication(_ publication: AppStatePublisher.Publication?) {
        guard let publication else { return }
        canonicalTimer = publication.canonicalTimer
        history = publication.history
        tasks = publication.tasks
        projectedAutoStartBreaks = publication.autoStartBreaks
        projectedSelectedTaskID = publication.selectedTaskID
        completionAlertTimerID = publication.completionAlertTimerID
        completionQueuedFor = publication.completionQueuedFor
        executeAlarmEffects(
            alarmEffectCoordinator.effects(for: publication.effects)
        )
        scheduleTimerCompletion()
        watchSync.push()
    }

    private func applyWorkspaceMutation(
        _ transition: SynchronizedWorkspaceMutationController.Transition
    ) -> Bool {
        if transition.projection == nil {
            return applyLocalWorkspaceMutation(transition)
        }
        var working = transition.state
        for effect in transition.effects {
            if case .setExplicitPhaseSelection(let value) = effect {
                working.hasExplicitPhaseSelection = value
            }
        }
        let publication = prepareWorkspacePublication(state: working, output: transition.projection)
        timerState = publication?.state ?? working
        var deferred: [SynchronizedWorkspaceMutationController.Effect] = []
        for effect in transition.effects {
            switch effect {
            case .setExplicitPhaseSelection:
                break
            case .persist:
                // Non-atomic write keeps old success semantics:
                // rollback target is the current proposal.
                guard commitMutationDurableWrite(previous: timerState) else {
                    return false
                }
            case .persistAtomically(let prev, _):
                guard commitMutationDurableWrite(previous: prev) else {
                    return false
                }
            default:
                deferred.append(effect)
            }
        }
        installPreparedPublication(publication)
        for effect in deferred {
            guard applyWorkspaceMutationEffect(effect) else { return false }
        }
        return true
    }

    private func applyLocalWorkspaceMutation(
        _ transition: SynchronizedWorkspaceMutationController.Transition
    ) -> Bool {
        var working = transition.state
        var deferred: [SynchronizedWorkspaceMutationController.Effect] = []
        for effect in transition.effects {
            switch effect {
            case .setExplicitPhaseSelection(let value):
                working.hasExplicitPhaseSelection = value
            case .persist, .persistAtomically:
                break
            default:
                deferred.append(effect)
            }
        }
        let previous = transition.effects.compactMap { effect -> PersistedTimerState? in
            if case .persistAtomically(let prev, _) = effect { return prev }
            return nil
        }.first ?? timerState
        let destination = persistenceDestination(for: working)
        let coordinatorTransition = accountSessionCoordinator.persistAtomically(
            previous: previous,
            proposed: working,
            to: destination,
            rebuildsOnRollback: true
        )
        guard applyPersistenceTransition(coordinatorTransition) else { return false }
        for effect in deferred {
            guard applyWorkspaceMutationEffect(effect) else { return false }
        }
        return true
    }

    private func applyWorkspaceMutationEffect(
        _ effect: SynchronizedWorkspaceMutationController.Effect
    ) -> Bool {
        switch effect {
        case .persist:
            _ = persist()
        case .persistAtomically(let previous, let rebuildsOnRollback):
            return persistAtomically(
                previous: previous,
                rebuildsOnRollback: rebuildsOnRollback
            )
        case .launchSync:
            Task { await sync() }
        case .setExplicitPhaseSelection(let value):
            timerState.hasExplicitPhaseSelection = value
        case .clearCompletionAlert(let timerID):
            if completionAlertTimerID == timerID { completionAlertTimerID = nil }
        case .alarm(let plan):
            executeAlarmPlan(plan)
        }
        return true
    }

    private func ownsAutomaticCompletion(for timerID: String) -> Bool {
        timerState.localTimerOwners[timerID] == timerState.deviceId
            || timerState.pendingCommands.contains {
                $0.type == .start && $0.timerId == timerID
            }
    }

    private var durableIrohTimerNeedingCompletion: CanonicalTimer? {
        guard replicationMode == .iroh,
              let timer = timerState.canonicalTimer,
              timer.status == .running || timer.status == .paused else { return nil }
        return timer
    }

    private func pruneLocalTimerOwners() {
        var retainedTimerIDs = Set(timerState.pendingCommands.lazy.filter {
            $0.type == .start
        }.map(\.timerId))
        for provisional in timerState.provisionalBreaks {
            retainedTimerIDs.insert(provisional.focusTimerId)
            retainedTimerIDs.insert(provisional.breakTimerId)
        }
        if let activeTimer {
            retainedTimerIDs.insert(activeTimer.id)
        }
        // Commit order prunes before presentation install, so the
        // projected timer above is still pre-sync. The reconciled base
        // below is already post-sync; without it a restored focus owner
        // is pruned and its alarm never rescheduled after a rejection.
        if let base = timerState.canonicalTimer,
           base.status == .running || base.status == .paused {
            retainedTimerIDs.insert(base.id)
        }
        timerState.localTimerOwners = timerState.localTimerOwners.filter {
            retainedTimerIDs.contains($0.key)
        }
    }

    static func derivedNextPhase(
        from history: [HistoryItem],
        on referenceDate: Date,
        calendar: Calendar = .current
    ) -> TimerPhase? {
        TimerSessionController.derivedNextPhase(
            from: history,
            on: referenceDate,
            calendar: calendar
        )
    }

    /// Swaps in a room workspace, reprojects, and reconciles the alarm
    /// across the swap so a departed running timer is cancelled and an
    /// adopted running timer is scheduled when this device owns it.
    /// Callers must set replicationMode before calling: projection reads it.
    /// Internal (not private) so WatchCommandIdentityTests drives the
    /// room-swap path without a local mutation.
    func adoptRoomWorkspace(_ state: PersistedTimerState) {
        let previousTimer = canonicalTimer
        timerState = state
        rebuildOptimisticState()
        // R52-AP03: room ownership changed, so deferred Watch settings from
        // the previous workspace are rejected as stale from here on.
        rotateWatchWorkspaceGeneration()
        reconcileAlarm(
            from: previousTimer,
            to: canonicalTimer,
            at: effectivePhysicalNow() ?? now()
        )
        // Non-mutation transition: no performWorkspaceMutation push runs.
        watchSync.push()
    }

    private func reconcileAlarm(
        from previousTimer: CanonicalTimer?,
        to currentTimer: CanonicalTimer?,
        at date: Date
    ) {
        executeAlarmPlan(
            timerSessionController.alarmPlan(
                from: previousTimer,
                to: currentTimer,
                at: date,
                ownsCurrentTimer: currentTimer.map {
                    ownsAutomaticCompletion(for: $0.id)
                } ?? false
            )
        )
    }

    private func enqueueTaskOperation(_ type: TaskOperationType, task: FocusTask) -> Bool {
        performWorkspaceMutation(.task(type, task))
    }

    private func cancelAlarm(timerID: String) {
        executeAlarmEffects([.cancel(timerID: timerID)])
    }

    /// Marks an automatic phase completion: raises the completion alert and
    /// plays the in-app chime when foreground (notification sounds are muted
    /// by the silent switch, so without this the completion is banner-only).
    /// Stopping the pending system alarm stays with stopCompletionAlertIfTimerStarted:
    /// every call site pairs the two, and both cancels would traverse the
    /// same serialized alarm queue, so cancelling here only duplicates it.
    private func noteCompletionAlert(timerID: String) {
        completionAlertTimerID = timerID
        guard CompletionChimePlayer.isForeground else { return }
        CompletionChimePlayer.shared.play()
    }

    private func stopCompletionAlertIfTimerStarted() {
        let transition = statePublisher.completionPresentation(
            alertTimerID: completionAlertTimerID,
            currentTimer: canonicalTimer
        )
        completionAlertTimerID = transition.alertTimerID
        executeAlarmEffects(alarmEffectCoordinator.effects(for: transition.effects))
    }

    private func completePermissionIntroduction() {
        defaults.set(true, forKey: Self.permissionIntroductionKey)
        needsPermissionIntroduction = false
    }

    private func executeAlarmPlan(
        _ plan: TimerSessionController.AlarmPlan
    ) {
        executeAlarmEffects(alarmEffectCoordinator.effects(for: plan))
    }

    private func executeAlarmEffects(_ effects: [AlarmEffectCoordinator.Effect]) {
        for effect in effects {
            switch effect {
            case .schedule(let timerID, let phase, _):
                enqueueAlarmOperation { [weak self] in
                    guard let self else { return }
                    let now = self.effectivePhysicalNow() ?? self.now()
                    guard let timer = self.canonicalTimer,
                          timer.id == timerID,
                          timer.status == .running else { return }
                    try await self.alarmScheduler.schedule(
                        timerID: timerID,
                        phase: phase,
                        duration: max(1, timer.remaining(at: now))
                    )
                }
            case .pause(let timerID):
                enqueueAlarmOperation { [alarmScheduler] in
                    try await alarmScheduler.pause(timerID: timerID)
                }
            case .resume(let timerID, let phase, _):
                enqueueAlarmOperation { [weak self] in
                    guard let self else { return }
                    let now = self.effectivePhysicalNow() ?? self.now()
                    guard let timer = self.canonicalTimer,
                          timer.id == timerID,
                          timer.status == .running else { return }
                    try await self.alarmScheduler.resume(
                        timerID: timerID,
                        phase: phase,
                        duration: max(1, timer.remaining(at: now))
                    )
                }
            case .cancel(let timerID):
                enqueueAlarmOperation { [alarmScheduler] in
                    try await alarmScheduler.cancel(timerID: timerID)
                }
            }
        }
    }

    private func enqueueAlarmOperation(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousOperation = alarmOperationTask
        alarmOperationTask = Task {
            await previousOperation?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                // Alarm failures stay silent: the timer continues in
                // Pomodorough. Sentry still captures the failure.
                Self.logger.error("alarmOperation failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
                SentryCapture.capture(error)
            }
        }
    }

    @discardableResult
    func rebuildOptimisticState() -> Bool {
        do {
            let output = try project(timerState)
            installProjection(output)
            return true
        } catch {
            Self.logger.error("rebuildOptimisticState failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.capture(error)
            installUnreducedBaseSnapshot()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func project(
        _ state: PersistedTimerState,
        base override: CoreProjectionBase? = nil,
        now projectionDate: Date? = nil
    ) throws -> CoreProjectionOutput {
        try timerSessionController.project(
            state,
            base: override,
            now: projectionDate,
            replicationMode: replicationMode,
            physicalNow: effectivePhysicalNow() ?? now()
        )
    }

    private func installProjection(_ output: CoreProjectionOutput) {
        let publication = statePublisher.publication(
            output: output,
            state: timerState,
            completionAlertTimerID: completionAlertTimerID,
            completionQueuedFor: completionQueuedFor
        )
        canonicalTimer = publication.canonicalTimer
        history = publication.history
        tasks = publication.tasks
        timerState = publication.state
        projectedAutoStartBreaks = publication.autoStartBreaks
        projectedSelectedTaskID = publication.selectedTaskID
        completionAlertTimerID = publication.completionAlertTimerID
        completionQueuedFor = publication.completionQueuedFor
        executeAlarmEffects(
            alarmEffectCoordinator.effects(for: publication.effects)
        )
        scheduleTimerCompletion()
        // Observation hook: every projection refreshes the watch reply cache,
        // covering room swaps, completions, sync, and bootstrap resolutions.
        watchSync.push()
    }

    private func installUnreducedBaseSnapshot() {
        cancelTimerCompletion()
        let publication = statePublisher.fallbackPublication(from: timerState)
        canonicalTimer = publication.canonicalTimer
        history = publication.history
        tasks = publication.tasks
        projectedAutoStartBreaks = publication.autoStartBreaks
        projectedSelectedTaskID = publication.selectedTaskID
        watchSync.push()
    }

    @discardableResult
    private func commitSynchronizedState(
        _ updated: PersistedTimerState,
        requiringTimerCommandIDs: Set<String> = [],
        requiringTaskOperationIDs: Set<String> = [],
        requiringDurationOperationIDs: Set<String> = [],
        requiringAutoStartOperationIDs: Set<String> = [],
        requiringSelectedTaskOperationIDs: Set<String> = []
    ) -> Bool {
        performWorkspaceMutation(.commit(.init(
            state: updated,
            requirements: .init(
                timerCommandIDs: requiringTimerCommandIDs,
                taskOperationIDs: requiringTaskOperationIDs,
                durationOperationIDs: requiringDurationOperationIDs,
                autoStartOperationIDs: requiringAutoStartOperationIDs,
                selectedTaskOperationIDs: requiringSelectedTaskOperationIDs
            )
        )))
    }

    private func trustedOccurrenceDate(localDate: Date) throws -> Date {
        try timerState.trustedOccurrenceDate(for: localDate, uptime: uptime())
    }

    private func effectivePhysicalNow() -> Date? {
        guard let physicalAnchor else { return nil }
        let currentUptime = uptime()
        let elapsed = currentUptime - physicalAnchor.uptime
        let candidate = physicalAnchor.wall.addingTimeInterval(elapsed)
        guard currentUptime.isFinite,
              currentUptime >= physicalAnchor.uptime,
              WireBounds.nonnegativeMilliseconds(for: elapsed) != nil,
              WireBounds.physicalMilliseconds(for: candidate) != nil else {
            return physicalAnchor.wall
        }
        return candidate
    }

    private func completeAuthenticatedSession(
        user: User,
        operation: AccountLifecycleController.Operation
    ) async {
        let route = accountSessionCoordinator.routeAuthenticatedSession(
            user,
            operation: operation,
            state: timerState,
            replicationMode: replicationMode
        )
        applyCoordinatorPublication(route.publication)
        switch route.action {
        case .ignored:
            return
        case .invalidPendingOperations:
            applyCoordinatorEffects(route.effects)
            return
        case .stageAccountSwitch(let state), .stageNoncentralized(let state):
            timerState = state
            applyCoordinatorEffects(route.effects)
        case .resumeCached(let state):
            timerState = state
            applyCoordinatorEffects(route.effects)
            await sync(force: true)
        case .bootstrap(let state, let request):
            timerState = state
            applyCoordinatorEffects(route.effects)
            if let request {
                await submitPersistedBootstrapResolution(
                    request,
                    generation: operation.generation
                )
            } else {
                await preflightBootstrapResolution(generation: operation.generation)
            }
        }
    }

    private func preflightBootstrapResolution(generation: Int, autoSubmits: Bool = true) async {
        let operation = accountSessionCoordinator.operation(generation: generation)
        let modeGeneration = roomReplicationController.modeGeneration
        let start = accountSessionCoordinator.beginBootstrapPreflight(
            operation: operation,
            workspace: centralizedWorkspace,
            user: user
        )
        guard case .started = applyCoordinatorTransition(start) else { return }
        do {
            guard let result = try await loadBootstrapPreflight(
                operation: operation,
                modeGeneration: modeGeneration
            ) else { return }
            try await applyBootstrapPreflight(result, autoSubmits: autoSubmits)
        } catch {
            await handleBootstrapFailure(
                error,
                stage: .preflight,
                operation: operation,
                modeGeneration: modeGeneration
            )
        }
    }

    private func loadBootstrapPreflight(
        operation: CentralizedAccountSessionCoordinator.Operation,
        modeGeneration: Int
    ) async throws -> AccountSynchronization.BootstrapPreflightTransition? {
        let sampledResponse = try await accountSessionCoordinator.sendBootstrapPreflight(
            state: timerState
        )
        guard accountSessionCoordinator.ownsCentralizedReplication(
            operation,
            modeGeneration: modeGeneration,
            workspace: centralizedWorkspace
        ), timerState.cachedUser == nil else { return nil }
        let transition = try accountSessionCoordinator.reconcileBootstrapPreflight(
            sampledResponse,
            state: timerState,
            localHistory: history,
            hasLocalState: hasLocalBootstrapState
        )
        let previousState = timerState
        timerState = transition.state
        guard persistAtomically(previous: previousState, rebuildsOnRollback: false) else {
            throw AppError.invalidResponse
        }
        return transition
    }

    private func applyBootstrapPreflight(
        _ result: AccountSynchronization.BootstrapPreflightTransition,
        autoSubmits: Bool
    ) async throws {
        let completion = accountSessionCoordinator.finishBootstrapPreflight(
            result,
            autoSubmits: autoSubmits
        )
        errorMessage = nil
        switch applyCoordinatorTransition(completion) {
        case .ignored, .started:
            return
        case .choose:
            return
        case .submit(let strategy, let snapshot):
            await submitBootstrapResolution(strategy: strategy, snapshot: snapshot)
        case .invalidResponse:
            throw AppError.invalidResponse
        }
    }

    private var hasLocalBootstrapState: Bool {
        !timerState.pendingCommands.isEmpty
            || !timerState.pendingTaskOperations.isEmpty
            || !timerState.pendingDurationOperations.isEmpty
            || !timerState.pendingAutoStartOperations.isEmpty
            || !timerState.pendingSelectedTaskOperations.isEmpty
            || timerState.canonicalTimer != nil
            || !timerState.history.isEmpty
            || !timerState.tasks.isEmpty
            || timerState.settings.durationsMs != .defaults
            || autoStartBreaks
    }

    private func submitBootstrapResolution(
        strategy: BootstrapResolutionStrategy,
        snapshot: BootstrapResponse
    ) async {
        guard replicationMode == .centralized,
              timerState.pendingBootstrapResolution == nil else { return }
        let includesLocalOperations = strategy != .keepRemote
        guard !includesLocalOperations || timerState.hasValidPendingWireOperations else {
            reportInvalidPendingOperations()
            return
        }
        let request: BootstrapResolveRequest
        do {
            request = try accountSessionCoordinator.makeBootstrapResolutionRequest(
                strategy: strategy,
                snapshot: snapshot,
                state: timerState
            )
            try accountSessionCoordinator.validateBootstrapRequest(request, state: timerState)
        } catch {
            await handleBootstrapFailure(error, stage: .submission(strategy),
                operation: accountSessionCoordinator.operation(generation: sessionGeneration),
                modeGeneration: roomReplicationController.modeGeneration)
            return
        }
        var retired = accountSessionCoordinator.retiredStateForBootstrapRequest(request, state: timerState)
        retired.pendingBootstrapResolution = request
        let previous = timerState
        timerState = retired
        guard persistAtomically(previous: previous, rebuildsOnRollback: true) else { return }
        await submitPersistedBootstrapResolution(request, generation: sessionGeneration)
    }

    private func submitPersistedBootstrapResolution(
        _ request: BootstrapResolveRequest,
        generation: Int
    ) async {
        let operation = accountSessionCoordinator.operation(generation: generation)
        let modeGeneration = roomReplicationController.modeGeneration
        let start = accountSessionCoordinator.beginBootstrapSubmission(
            request,
            operation: operation,
            workspace: centralizedWorkspace,
            user: user
        )
        guard case .started = applyCoordinatorTransition(start) else { return }
        do {
            try accountSessionCoordinator.validateBootstrapRequest(
                request,
                state: timerState
            )
            try await performBootstrapSubmission(
                request,
                operation: operation,
                modeGeneration: modeGeneration
            )
        } catch {
            await handleBootstrapFailure(
                error,
                stage: .submission(request.strategy),
                operation: operation,
                modeGeneration: modeGeneration
            )
        }
    }

    private func performBootstrapSubmission(
        _ request: BootstrapResolveRequest,
        operation: CentralizedAccountSessionCoordinator.Operation,
        modeGeneration: Int
    ) async throws {
        let sampledResponse = try await accountSessionCoordinator.sendBootstrapResolution(request, state: timerState)
        let receivedAt = effectivePhysicalNow() ?? now()
        guard accountSessionCoordinator.ownsCentralizedReplication(
            operation,
            modeGeneration: modeGeneration,
            workspace: centralizedWorkspace
        ), timerState.pendingBootstrapResolution == request,
              let bootstrapUser = timerState.bootstrapUser else { return }
        let previousTimer = activeTimer
        let transition = try accountSessionCoordinator.reconcileBootstrapResolution(
            sampledResponse,
            request: request,
            state: timerState,
            user: bootstrapUser
        )
        try installBootstrapResolution(transition.state)
        reconcileAlarm(from: previousTimer, to: activeTimer, at: receivedAt)
        watchSync.push()
        await sync(force: true)
    }

    private func handleBootstrapFailure(
        _ error: Error,
        stage: AccountLifecycleController.BootstrapStage,
        operation: CentralizedAccountSessionCoordinator.Operation,
        modeGeneration: Int
    ) async {
        let failure = accountSessionCoordinator.bootstrapFailure(
            error,
            stage: stage,
            operation: operation,
            modeGeneration: modeGeneration,
            workspace: centralizedWorkspace
        )
        switch applyCoordinatorTransition(failure) {
        case .stale, .retryable:
            return
        case .unauthorized(let operation):
            await invalidateUnauthorizedSession(operation: operation)
        case .restartPreflight:
            timerState.pendingBootstrapResolution = nil
            persist()
            await preflightBootstrapResolution(
                generation: operation.generation,
                autoSubmits: false
            )
        }
    }

    private func installBootstrapResolution(_ resolved: PersistedTimerState) throws {
        // R50-AP02: prepare/commit/install. Never publish the proposed
        // projection or effects before the durable commit. Mirrors
        // commitSyncedState. Uncertain replacement keeps observed
        // durable state under quarantine via persistAtomically.
        let projection = try project(resolved)
        let previousState = timerState
        let publication = prepareWorkspacePublication(state: resolved, output: projection)
        timerState = publication?.state ?? resolved
        pruneLocalTimerOwners()
        guard persistAtomically(previous: previousState, rebuildsOnRollback: true) else {
            reportBootstrapInstallPersistFailure()
            throw AppError.invalidResponse
        }
        installPreparedPublication(publication)
        applyCoordinatorPublication(accountSessionCoordinator.finishBootstrapResolution())
        errorMessage = nil
    }

    private func reportBootstrapInstallPersistFailure() {
        let quarantined = snapshotLoadFailure != nil
        let outcome: BootstrapInstallDiagnostics.Outcome = quarantined ? .uncertain : .failed
        let diagnostic = BootstrapInstallDiagnostics(
            outcome: outcome,
            quarantined: quarantined,
            pendingOperations: pendingChangeCount
        )
        Self.logger.error("\(DiagnosticPrivacy.publicSummary(diagnostic), privacy: .public)")
        SentryCapture.captureRecurring(key: diagnostic.key, limit: 3, error: diagnostic)
    }

    private func verifyRestoredSession(
        operation: AccountLifecycleController.Operation
    ) async {
        let verification = await accountSessionCoordinator.verifyRestoredSession(
            operation,
            hasAccountState: timerState.cachedUser != nil || timerState.bootstrapUser != nil
        )
        switch applyCoordinatorTransition(verification) {
        case .ignored, .retry:
            return
        case .verified(let user, let operation):
            await completeAuthenticatedSession(user: user, operation: operation)
        case .unauthorized(let operation):
            await invalidateUnauthorizedSession(operation: operation)
        }
    }

    private func invalidateUnauthorizedSession(generation: Int) async {
        await invalidateUnauthorizedSession(
            operation: accountSessionCoordinator.operation(generation: generation)
        )
    }

    private func invalidateUnauthorizedSession(
        operation: AccountLifecycleController.Operation
    ) async {
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        guard let transition = accountSessionCoordinator.invalidateUnauthorized(
            operation,
            preservesBootstrapResolution: preservesBootstrapResolution,
            pendingStrategy: timerState.pendingBootstrapResolution?.strategy
        ) else { return }
        applyAccountReset(transition)
        errorMessage = AppError.unauthorized.localizedDescription
        _ = await accountSessionCoordinator.clearTokens()
    }

    @discardableResult
    private func persist() -> Bool {
        guard snapshotLoadFailure == nil else { return false }
        return applyPersistenceTransition(accountSessionCoordinator.persist(
            timerState,
            to: persistenceDestination(for: timerState)
        ))
    }

    @discardableResult
    private func persistAtomically(
        previous: PersistedTimerState,
        rebuildsOnRollback: Bool
    ) -> Bool {
        guard snapshotLoadFailure == nil else { return false }
        return applyPersistenceTransition(accountSessionCoordinator.persistAtomically(
            previous: previous,
            proposed: timerState,
            to: persistenceDestination(for: timerState),
            rebuildsOnRollback: rebuildsOnRollback
        ))
    }

    private func persistenceDestination(
        for state: PersistedTimerState
    ) -> AppStatePersistenceCoordinator.Destination {
        replicationMode == .iroh
            ? .iroh(roomReplicationController.captureLocalState(state))
            : .local
    }

    private func applyPersistenceTransition(
        _ transition: CentralizedAccountSessionCoordinator.Transition<
            CentralizedAccountSessionCoordinator.PersistenceAction
        >
    ) -> Bool {
        applyCoordinatorPublication(transition.publication)
        timerState = transition.action.state
        snapshotLoadFailure = persistence.snapshotLoadFailure
        if snapshotLoadFailure != nil {
            roomReplicationController.cancelRetry()
            roomReplicationController.cancelCentralizedStreams()
        }
        applyCoordinatorEffects(transition.effects)
        return transition.action.succeeded
    }

    @discardableResult
    private func applyCoordinatorTransition<Action: Sendable>(
        _ transition: CentralizedAccountSessionCoordinator.Transition<Action>
    ) -> Action {
        applyCoordinatorPublication(transition.publication)
        applyCoordinatorEffects(transition.effects)
        return transition.action
    }

    private func applyCoordinatorPublication(
        _ publication: CentralizedAccountSessionCoordinator.PublicationSnapshot
    ) {
        sessionState = publication.sessionState
        isSyncing = publication.isSyncing
        isOffline = publication.isOffline
        historyResolutionState = publication.historyResolutionState
        localHistoryResolutionCount = publication.localHistoryResolutionCount
        remoteHistoryResolutionCount = publication.remoteHistoryResolutionCount
        if !isHistoryResolutionOfflineEscapeAllowed {
            isHistoryResolutionOfflineEscapeActive = false
        }
        scheduleTimerCompletion()
    }

    private func applyCoordinatorEffects(
        _ effects: [CentralizedAccountSessionCoordinator.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .resetCentralizedLifecycle:
                roomReplicationController.resetCentralizedLifecycle()
            case .signOutIdentity:
                accountSessionCoordinator.signOutIdentity()
            case .cancelRetry:
                roomReplicationController.cancelRetry()
            case .scheduleRetry:
                roomReplicationController.scheduleRetry()
            case .cancelCentralizedStreams:
                roomReplicationController.cancelCentralizedStreams()
            case .startCentralizedStreams:
                roomReplicationController.startCentralizedStreams()
            case .persist:
                _ = persist()
            case .rebuildProjection:
                _ = rebuildOptimisticState()
            case .removeLegacyTasks:
                accountSessionCoordinator.removeLegacyTasks()
            case .reportInvalidPendingOperations:
                reportInvalidPendingOperations()
            case .presentError(let message):
                errorMessage = message
            case .presentPersistenceFailure(let message, let quarantined):
                conflictMessage = message
                if quarantined { irohStatus = .conflict }
            }
        }
    }

    private func applyRoomProjection(_ projection: RoomReplicationProjection) {
        let transition = roomReplicationController.projectionTransition(for: projection)
        guard case .projectionApplied(let state, let message) = transition else { return }
        let previous = activeTimer
        timerState = state
        if let message { errorMessage = message }
        rebuildOptimisticState()
        reconcileAlarm(from: previous, to: activeTimer, at: effectivePhysicalNow() ?? now())
    }

    private func reportInvalidLocalClock() {
        conflictMessage = String(localized: "Saved sequence or trusted-time state is invalid. No local change was saved.")
        errorMessage = AppError.invalidLocalClock.localizedDescription
    }

    // AP82: per-site clock vs core split. Internal so SentryCaptureTests
    // drives each site with SharedCoreError vs invalidLocalClock.
    func reportFinishPlanFailure(_ error: Error) {
        if error as? AppError == .invalidLocalClock {
            reportInvalidLocalClock()
        } else {
            Self.logger.error("finish failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.captureOnce(key: "timer-finish-plan", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func reportCentralizedBreakFailure(_ error: Error) {
        if error as? AppError == .invalidLocalClock {
            reportInvalidLocalClock()
        } else {
            Self.logger.error("centralized break failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.captureOnce(key: "timer-finish-centralized-break", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func reportIrohBreakFailure(_ error: Error) {
        if error as? AppError == .invalidLocalClock {
            reportInvalidLocalClock()
        } else {
            Self.logger.error("iroh break failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.captureOnce(key: "timer-finish-iroh-break", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func reportCompletionDeadlineFailure(_ error: Error) {
        if error as? AppError == .invalidLocalClock {
            reportInvalidLocalClock()
        } else {
            Self.logger.error("completion deadline failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
            SentryCapture.captureOnce(key: "timer-completion-deadline", error: error)
            errorMessage = error.localizedDescription
        }
    }

    private func reportInvalidPendingOperations() {
        conflictMessage = String(localized: "Queued changes contain invalid sequence or trusted-time values.")
        errorMessage = String(localized: "Sync paused because queued changes failed local validation. No queued changes were sent or modified.")
        isOffline = false
        roomReplicationController.cancelCentralizedStreams()
    }

    private static let accountDeletionStateKey = "account-deletion-state-v1"
    private static let accountDeletionRoomIDsKey = "account-deletion-room-ids-v1"
    private static let permissionIntroductionKey = "permission-introduction-completed-v1"
    private static let replicationModeKey = "replication-mode-v1"
    // R52-AP03: phone-owned workspace epoch binding deferred Watch settings
    // to the workspace that was current when the watch built them. Rotated
    // at account and room ownership changes; persisted across restarts.
    private static let watchWorkspaceGenerationKey = "watch-workspace-generation-v1"

    private static var platform: String {
#if os(iOS)
        "ios"
#else
        "macos"
#endif
    }
}

#if DEBUG
extension AppModel {
    enum PreviewScenario {
        case local
        case populated
        case running
        case resolving
        case signedIn
    }

    static func preview(_ scenario: PreviewScenario = .populated) -> AppModel {
        let defaults = UserDefaults(suiteName: "PomodoroughPreview-\(UUID().uuidString)")!
        let roomURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodorough-preview-\(UUID().uuidString).json")
        let roomStore = IrohRoomStore(fileURL: roomURL, secretStore: PreviewRoomSecretStore())
        let api = APIClient(keychain: PreviewTokenStore())
        let model = AppModel(
            api: api,
            defaults: defaults,
            roomStore: roomStore,
            endpointKeyStore: PreviewEndpointKeyStore(),
            alarmScheduler: PreviewAlarmScheduler(),
            googleIdentityProvider: PreviewGoogleIdentityProvider(),
            retryDelay: .seconds(60),
            now: { PreviewFixtures.now },
            uptime: { 10_000 }
        )

        var state = PersistedTimerState.fresh()
        state.deviceId = "preview-device"
        state.tasks = [PreviewFixtures.task, PreviewFixtures.secondTask]
        state.knownTasks = state.tasks
        state.selectedTaskID = PreviewFixtures.task.id
        state.history = PreviewFixtures.history
        state.settings.autoStartBreaks = true
        if scenario == .running {
            state.canonicalTimer = PreviewFixtures.runningTimer
        }

        model.timerState = state
        model.replicationMode = scenario == .resolving || scenario == .signedIn ? .centralized : .offline
        let previewSession: AccountSessionState = scenario == .resolving || scenario == .signedIn
            ? .signedIn(User(id: "preview-user", email: "alex@example.com", name: "Alex", avatarUrl: ""))
            : .localOnly
        model.needsPermissionIntroduction = false
        model.applyCoordinatorPublication(model.accountSessionCoordinator.installPreviewPublication(
            .init(
                sessionState: previewSession,
                historyResolutionState: scenario == .resolving ? .choosing : .none,
                localHistoryResolutionCount: scenario == .resolving ? 2 : 0,
                remoteHistoryResolutionCount: scenario == .resolving ? 4 : 0
            )
        ))
        model.rebuildOptimisticState()
        return model
    }
}
#endif
