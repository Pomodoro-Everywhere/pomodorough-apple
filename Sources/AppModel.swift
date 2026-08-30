import Foundation
import Observation

private enum AccountDeletionPurgeState: String {
    case prepared
    case remoteCommitted = "remote_committed"
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

@MainActor
@Observable
final class AppModel {
    typealias SessionState = AccountSessionState
    typealias HistoryResolutionState = AccountHistoryResolutionState

    private let api: APIClient
    private let defaults: UserDefaults
    private let accountDeletionJournal: AccountDeletionJournal?
    private let roomStore: IrohRoomStore
    private let endpointKeyStore: any IrohEndpointKeyStoring
    private let alarmScheduler: any TimerAlarmScheduling
    private let retryDelay: Duration
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let timerSessionController: TimerSessionController
    private let workspaceMutationController: SynchronizedWorkspaceMutationController
    private let accountSessionCoordinator: CentralizedAccountSessionCoordinator
    private let statePublisher = AppStatePublisher()
    private let alarmEffectCoordinator: AlarmEffectCoordinator
    private let taskIdentityCoreProvider: @MainActor () throws -> SharedCore
    private var timerState: PersistedTimerState
    private var accountDeletionPurgeState: AccountDeletionPurgeState?
    private var accountDeletionRecord: AccountDeletionJournal.Record?
    @ObservationIgnored private var alarmOperationTask: Task<Void, Never>?
    @ObservationIgnored private var centralizedSyncTask: Task<Void, Never>?
    @ObservationIgnored private var centralizedSyncTaskID: UUID?
    @ObservationIgnored private var completionQueuedFor: String?
    @ObservationIgnored private var physicalAnchor: (wall: Date, uptime: TimeInterval)?
    @ObservationIgnored private var taskIdentityCore: SharedCore?
    @ObservationIgnored private var projectedAutoStartBreaks = false
    @ObservationIgnored private var projectedSelectedTaskID: UUID?
    @ObservationIgnored private lazy var roomReplicationController = makeRoomReplicationController()

    private(set) var sessionState: SessionState = .restoring
    private(set) var canonicalTimer: CanonicalTimer?
    private(set) var history: [HistoryItem] = []
    private(set) var tasks: [FocusTask] = []
    private(set) var isWorking = false
    private(set) var isSyncing = false
    private(set) var isOffline = false
    private(set) var conflictMessage: String?
    private(set) var historyResolutionState: HistoryResolutionState = .none
    private(set) var localHistoryResolutionCount = 0
    private(set) var remoteHistoryResolutionCount = 0
    private(set) var needsPermissionIntroduction = false
    private(set) var replicationMode: ReplicationMode
    private(set) var irohStatus: IrohConnectionStatus = .stopped
    private(set) var roomInvite: String?
    private(set) var completionAlertTimerID: String?
    private(set) var isIrohRoomLeaveConfirmationPresented = false
    private(set) var isLeavingIrohRoom = false
    var errorMessage: String?

    init(
        api: APIClient = APIClient(),
        defaults: UserDefaults = .standard,
        accountDeletionJournal: AccountDeletionJournal? = nil,
        durableLocalStore: AtomicDurableFileStore? = nil,
        roomStore: IrohRoomStore = IrohRoomStore(),
        endpointKeyStore: any IrohEndpointKeyStoring = IrohEndpointKeychainStore(),
        alarmScheduler: (any TimerAlarmScheduling)? = nil,
        googleIdentityProvider: any GoogleIdentityProviding = SystemGoogleIdentityProvider(),
        retryDelay: Duration = .seconds(5),
        now: @escaping () -> Date = { .now },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore = {
            try SharedCore.bundled()
        }
    ) {
        let startup = Self.makeStartup(
            defaults: defaults, accountDeletionJournal: accountDeletionJournal,
            durableLocalStore: durableLocalStore, roomStore: roomStore,
            now: now, uptime: uptime, sharedCoreProvider: sharedCoreProvider)
        self.api = api
        self.defaults = defaults
        self.accountDeletionJournal = startup.accountDeletionJournal
        self.roomStore = roomStore
        self.endpointKeyStore = endpointKeyStore
        self.alarmScheduler = alarmScheduler ?? TimerAlarmScheduler()
        self.retryDelay = retryDelay
        self.now = now
        self.uptime = uptime
        timerSessionController = startup.timerSessionController
        workspaceMutationController = SynchronizedWorkspaceMutationController(
            timerSessionController: startup.timerSessionController
        )
        accountSessionCoordinator = Self.makeAccountSessionCoordinator(
            api: api,
            googleIdentityProvider: googleIdentityProvider,
            sharedCoreProvider: sharedCoreProvider,
            persistence: startup.persistence,
            initialState: startup.initialState.transition.state
        )
        alarmEffectCoordinator = AlarmEffectCoordinator(timerSessionController: startup.timerSessionController)
        taskIdentityCoreProvider = sharedCoreProvider
        replicationMode = startup.initialState.replicationMode
        timerState = startup.initialState.transition.state
        accountDeletionRecord = startup.accountDeletionRecovery.record
        accountDeletionPurgeState = startup.accountDeletionRecovery.purgeState
        physicalAnchor = startup.initialState.physicalAnchor
        needsPermissionIntroduction = startup.initialState.needsPermissionIntroduction
        restoreInitialState(startup.initialState.transition)
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

    private static func loadAccountDeletionRecovery(
        journal: AccountDeletionJournal?,
        defaults: UserDefaults,
        roomStore: IrohRoomStore
    ) -> AccountDeletionRecovery {
        let journalLoad = journal.map { (try? $0.load()) ?? .corrupt }
        switch journalLoad {
        case .record(let record):
            let purgeState: AccountDeletionPurgeState = record.phase == .prepared
                ? .prepared : .remoteCommitted
            return AccountDeletionRecovery(record: record, purgeState: purgeState)
        case .corrupt:
            let topology = try? roomStore.accountDeletionTopology()
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
        try? AtomicDurableFileStore(
            fileURL: productionStorageURL("account-deletion-v1.json")
        ).remove()
        try? AtomicDurableFileStore(
            fileURL: productionStorageURL("timer-state-v2.json")
        ).remove()
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
            persistence: persistence
        )
    }

    private func restoreInitialState(
        _ transition: AppStatePersistenceCoordinator.LoadTransition
    ) {
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

    deinit {
        alarmOperationTask?.cancel()
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
            makeService: { [roomStore, endpointKeyStore] handlers in
                IrohReplicationService(
                    store: roomStore,
                    keyStore: endpointKeyStore,
                    statusHandler: { handlers.status($0) },
                    projectionHandler: { handlers.projection($0, $1) }
                )
            }
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
        accountDeletionPurgeState != nil
            || isHistoryResolutionBlocking
            || pendingAccountSwitchUser != nil
    }
    var hasPendingAccountDeletionRecovery: Bool { accountDeletionPurgeState != nil }
    var isHistoryResolutionBlocking: Bool {
        replicationMode == .centralized && (historyResolutionState != .none
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
    var deviceMark: String { String(timerState.deviceId.suffix(4)).uppercased() }

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

    func selectPhase(_ phase: TimerPhase) {
        _ = performWorkspaceMutation(.selectPhase(phase))
    }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        _ = performWorkspaceMutation(.setDurationMinutes(minutes, for: phase))
    }

    @discardableResult
    func addTask(_ title: String) async -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
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
            errorMessage = error.localizedDescription
            return false
        }
        guard !tasks.contains(where: { $0.id == task.id }) else { return true }
        return enqueueTaskOperation(.upsert, task: task)
    }

    func deleteTask(id: UUID) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        _ = enqueueTaskOperation(.delete, task: task)
    }

    func task(forTimerID timerID: String) -> FocusTask? {
        statePublisher.task(forTimerID: timerID, snapshot: publicationSnapshot)
    }

    func taskSummaries(for date: Date = .now, calendar: Calendar = .current) -> [TaskDailySummary] {
        statePublisher.taskSummaries(
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
        try? await alarmScheduler.requestAuthorization()
        completePermissionIntroduction()
    }

    func skipTimerAlertPermissions() {
        completePermissionIntroduction()
    }

    func signIn() {
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
        guard let state = accountSessionCoordinator.confirmAccountSwitch(
            state: timerState,
            authenticatedUser: user
        ) else { return }
        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id, reportsError: false)
        }
        applyCoordinatorPublication(accountSessionCoordinator.publication)
        let saved = accountSessionCoordinator.persist(state, to: .local)
        guard applyPersistenceTransition(saved) else {
            errorMessage = String(localized: "Account switch paused because local data could not be saved.")
            return
        }
        rebuildOptimisticState()
        await sync(force: true)
    }

    func cancelAccountSwitch() async {
        guard let transition = accountSessionCoordinator.beginAccountSwitchCancellation(
            hasPendingAccountSwitch: timerState.pendingAccountSwitchUser != nil,
            isWorking: isWorking
        ) else { return }
        isWorking = true
        defer { isWorking = false }
        if let failure = await accountSessionCoordinator.logout() {
            errorMessage = failure
            return
        }
        applyAccountReset(transition)
        timerState.pendingAccountSwitchUser = nil
        persist()
    }

    func signOut() {
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        guard let transition = accountSessionCoordinator.beginSignOut(
            isWorking: isWorking,
            preservesBootstrapResolution: preservesBootstrapResolution,
            pendingStrategy: timerState.pendingBootstrapResolution?.strategy
        ) else { return }
        isWorking = true
        Task {
            await persistLogoutThenReset(
                transition,
                preservesBootstrapResolution: preservesBootstrapResolution
            )
        }
    }

    private func persistLogoutThenReset(
        _ transition: CentralizedAccountSessionCoordinator.Transition<
            CentralizedAccountSessionCoordinator.ResetAction
        >,
        preservesBootstrapResolution: Bool
    ) async {
        defer { isWorking = false }
        if let failure = await accountSessionCoordinator.logout() {
            errorMessage = failure
            return
        }
        if !preservesBootstrapResolution, let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id)
        }
        applyAccountReset(transition)
        clearSignedOutState(preservesBootstrapResolution: preservesBootstrapResolution)
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

    private func clearSignedOutState(preservesBootstrapResolution: Bool) {
        let transition = accountSessionCoordinator.signedOutStorageTransition(
            state: timerState,
            replicationMode: replicationMode,
            preservesBootstrapResolution: preservesBootstrapResolution,
            activeReturnState: roomStore.activeReturnState
        )
        timerState = transition.state
        if let returnState = transition.irohReturnState {
            try? roomStore.replaceActiveReturnState(returnState)
        }
        if transition.rebuildsProjection { rebuildOptimisticState() }
        persist()
    }

    func deleteAccount(confirmation: String) async {
        guard confirmation == "DELETE", isSignedIn, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        guard let topology = try? roomStore.accountDeletionTopology(),
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
            guard let discovered = try? roomStore.accountDeletionTopology() else {
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

    private func finishConfirmedAccountDeletion() async {
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
            quarantineAccountDeletion()
            errorMessage = String(localized: "Account deletion was confirmed; use Retry account deletion to continue room cleanup.")
            return
        }
        guard credentialsCleared else {
            errorMessage = String(localized: "Account data was removed; use Retry account deletion to continue credential cleanup.")
            return
        }
        guard clearAccountDeletionRoomIDs() else {
            errorMessage = String(localized: "Account data was removed; use Retry account deletion to continue room cleanup.")
            return
        }
        guard clearAccountDeletionState() else {
            errorMessage = String(localized: "Local cleanup completed; use Retry account deletion to continue recovery-state cleanup.")
            return
        }
    }

    private func quarantineAccountDeletion() {
        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id, reportsError: false)
        }
        applyAccountReset(accountSessionCoordinator.completeDeletion())
        timerState = .fresh()
        canonicalTimer = nil
        history = []
        tasks = []
        completionAlertTimerID = nil
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
        guard let prior = try? journal.load() else { return (.unknown, false) }
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
            completedWithoutError = false
        }
        guard let current = try? journal.load() else {
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

    private func clearAccountDeletionState() -> Bool {
        if let accountDeletionJournal {
            do {
                try accountDeletionJournal.clear()
                guard try accountDeletionJournal.load() == .absent else { return false }
                accountDeletionRecord = nil
                accountDeletionPurgeState = nil
                return true
            } catch {
                return false
            }
        }
        defaults.removeObject(forKey: Self.accountDeletionStateKey)
        guard defaults.object(forKey: Self.accountDeletionStateKey) == nil else { return false }
        accountDeletionPurgeState = nil
        return true
    }

    private func persistAccountDeletionRoomIDs(_ roomIDs: [String]) -> Bool {
        guard let data = try? JSONEncoder().encode(roomIDs.sorted()) else { return false }
        defaults.set(data, forKey: Self.accountDeletionRoomIDsKey)
        return defaults.data(forKey: Self.accountDeletionRoomIDsKey) == data
    }

    private func accountDeletionRoomIDs() -> [String]? {
        if accountDeletionJournal != nil { return accountDeletionRecord?.roomIDs }
        guard let data = defaults.data(forKey: Self.accountDeletionRoomIDsKey) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
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

    func start() {
        _ = performWorkspaceMutation(.startTimer)
    }

    func pause(at explicitDate: Date? = nil) {
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        _ = performWorkspaceMutation(.pauseTimer(at: date))
    }

    func resume(at explicitDate: Date? = nil) {
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        _ = performWorkspaceMutation(.resumeTimer(at: date))
    }

    func finish(at explicitDate: Date? = nil) {
        guard !isWorkspaceMutationBlocked else { return }
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        finish(at: date, cancelsAlarm: true)
    }

    @discardableResult
    private func finish(
        at date: Date,
        cancelsAlarm: Bool,
        timer explicitTimer: CanonicalTimer? = nil,
        automatic: Bool = false
    ) -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
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
            reportInvalidLocalClock()
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
            reportInvalidLocalClock()
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

    func clear() {
        _ = performWorkspaceMutation(.clearTimer)
    }

    func stopSound() {
        guard let alertTimerID = completionAlertTimerID else { return }
        completionAlertTimerID = nil
        cancelAlarm(timerID: alertTimerID, reportsError: false)
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = durableIrohTimerNeedingCompletion ?? canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              completionQueuedFor != timer.id else { return }
        if replicationMode == .iroh {
            completeIrohTimerIfNeeded(timer, at: date)
            return
        }
        if finish(at: date, cancelsAlarm: false, timer: timer, automatic: true) {
            completionAlertTimerID = timer.id
            stopCompletionAlertIfTimerStarted()
            completionQueuedFor = canonicalTimer?.status == .running ? timer.id : nil
        }
    }

    private func completeIrohTimerIfNeeded(_ timer: CanonicalTimer, at date: Date) {
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
            errorMessage = error.localizedDescription
        }
    }

    private func persistCompletedIrohTimer(_ state: PersistedTimerState, timerID: String) {
        timerState = state
        rebuildOptimisticState()
        _ = persist()
        completionAlertTimerID = timerID
        stopCompletionAlertIfTimerStarted()
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
            reportInvalidLocalClock()
            return
        }
        guard let preparation else { return }
        guard commitSynchronizedState(
            preparation.state,
            requiringTimerCommandIDs: [preparation.command.id]
        ) else { return }
        completionAlertTimerID = timer.id
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

    func sync(force: Bool = false, showsActivity: Bool = true) async {
        let start = accountSessionCoordinator.beginSync(
            workspace: centralizedWorkspace,
            force: force,
            showsActivity: showsActivity
        )
        switch applyCoordinatorTransition(start) {
        case .ignored, .coalesced:
            return
        case .verify(let operation):
            await verifyRestoredSession(operation: operation)
            return
        case .invalidPendingOperations:
            return
        case .started(let lease):
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runSync(lease)
            }
            centralizedSyncTaskID = taskID
            centralizedSyncTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if centralizedSyncTaskID == taskID {
                centralizedSyncTask = nil
                centralizedSyncTaskID = nil
            }
        }
    }

    private func quiesceCentralizedSyncForAccountDeletion() async {
        roomReplicationController.cancelCentralizedStreams()
        applyCoordinatorPublication(accountSessionCoordinator.quiesce())
        let task = centralizedSyncTask
        task?.cancel()
        await task?.value
    }

    private func runSync(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async {
        var allowsFollowUpSync = true
        defer {
            finishSync(lease, allowsFollowUp: allowsFollowUpSync)
        }
        do {
            try await performSync(lease)
        } catch {
            allowsFollowUpSync = await handleSyncFailure(error, lease: lease)
        }
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
    ) async throws {
        repeat {
            guard try await performSyncRound(lease) else { return }
        } while centralizedWorkspace.hasPendingOperations
        _ = applyCoordinatorTransition(accountSessionCoordinator.finishSyncRounds(
            lease,
            workspace: centralizedWorkspace
        ))
    }

    private func performSyncRound(
        _ lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async throws -> Bool {
        let plan = accountSessionCoordinator.makeSyncPlan(state: timerState)
        guard !plan.batch.commands.isEmpty || timerState.pendingCommands.isEmpty else {
            throw AppError.invalidResponse
        }
        let previousTimer = activeTimer
        let sampledResponse = try await accountSessionCoordinator.sendSync(plan)
        let receivedAt = effectivePhysicalNow() ?? now()
        guard accountSessionCoordinator.ownsCentralizedReplication(
            lease.operation,
            modeGeneration: lease.modeGeneration,
            workspace: centralizedWorkspace
        ) else { return false }
        let transition = try accountSessionCoordinator.reconcileSync(
            sampledResponse,
            plan: plan,
            state: timerState
        )
        if let message = transition.conflictMessage { conflictMessage = message }
        try commitSyncedState(
            transition.state,
            previousTimer: previousTimer,
            receivedAt: receivedAt
        )
        return true
    }

    private func commitSyncedState(
        _ state: PersistedTimerState,
        previousTimer: CanonicalTimer?,
        receivedAt: Date
    ) throws {
        let projection = try project(state)
        let previousState = timerState
        timerState = state
        installProjection(projection)
        pruneLocalTimerOwners()
        guard persistAtomically(previous: previousState, rebuildsOnRollback: true) else {
            throw AppError.invalidResponse
        }
        reconcileAlarm(from: previousTimer, to: activeTimer, at: receivedAt)
        applyCoordinatorPublication(accountSessionCoordinator.markSyncSucceeded())
        errorMessage = nil
    }

    private func handleSyncFailure(
        _ error: Error,
        lease: CentralizedAccountSessionCoordinator.SyncLease
    ) async -> Bool {
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

    func refreshAfterForeground() async {
        guard accountDeletionPurgeState == nil else { return }
        completionQueuedFor = nil
        let action = await roomReplicationController.refreshAfterForeground(
            environment: roomReplicationEnvironment
        )
        if action == .synchronize { await sync(force: true) }
    }

    func setSceneActive(_ active: Bool) {
        guard accountDeletionPurgeState == nil else { return }
        roomReplicationController.setSceneActive(active, environment: roomReplicationEnvironment)
    }

    func setReplicationMode(_ mode: ReplicationMode) async {
        guard accountDeletionPurgeState == nil else { return }
        guard mode != replicationMode else {
            if mode == .iroh {
                roomReplicationController.scheduleIrohStartup(environment: roomReplicationEnvironment)
            }
            return
        }
        errorMessage = nil
        roomInvite = nil
        let transition = await roomReplicationController.changeMode(
            to: mode,
            environment: roomReplicationEnvironment
        )
        guard case .modeChanged(let target, let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return
        }
        timerState = state
        replicationMode = target
        defaults.set(target.rawValue, forKey: Self.replicationModeKey)
        rebuildOptimisticState()
        persist()
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
        guard accountDeletionPurgeState == nil else { return false }
        let transition = await roomReplicationController.createRoom(
            name: rawName,
            environment: roomReplicationEnvironment
        )
        guard case .roomCreated(let state, let invite, let status) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return false
        }
        timerState = state
        replicationMode = .iroh
        defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
        rebuildOptimisticState()
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
            durationsMs: timerState.settings.durationsMs,
            autoStartBreaks: autoStartBreaks,
            selectedTaskId: timerState.selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: timerState.hlcWallMs,
            hlcCounter: timerState.hlcCounter
        )
    }

    private static func emptyIrohGenesis(from state: PersistedTimerState) -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: state.canonicalTimer,
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
    }

    func refreshIrohInvite() async {
        guard accountDeletionPurgeState == nil else { return }
        let transition = await roomReplicationController.refreshInvite(
            environment: roomReplicationEnvironment
        )
        if case .inviteRefreshed(let invite) = transition { roomInvite = invite }
        if case .failed(let message) = transition { errorMessage = message }
    }

    func joinIrohRoom(inviteText: String) async -> Bool {
        guard accountDeletionPurgeState == nil else { return false }
        let transition = await roomReplicationController.joinRoom(
            inviteText: inviteText,
            environment: roomReplicationEnvironment
        )
        guard case .roomJoined(let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return false
        }
        timerState = state
        replicationMode = .iroh
        defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
        rebuildOptimisticState()
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
        guard accountDeletionPurgeState == nil else { return }
        guard replicationMode == .iroh,
              isIrohRoomLeaveConfirmationPresented,
              !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = false
        isLeavingIrohRoom = true
        defer { isLeavingIrohRoom = false }
        let transition = await roomReplicationController.leaveRoom(
            environment: roomReplicationEnvironment
        )
        guard case .roomLeft(let state) = transition else {
            if case .failed(let message) = transition { errorMessage = message }
            return
        }
        timerState = state
        replicationMode = .offline
        defaults.set(ReplicationMode.offline.rawValue, forKey: Self.replicationModeKey)
        roomInvite = nil
        rebuildOptimisticState()
        persist()
    }

    func syncIrohNow() async {
        guard accountDeletionPurgeState == nil else { return }
        await roomReplicationController.syncIroh(environment: roomReplicationEnvironment)
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
            return timerState.settings.selectedPhase
        }
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
            ) else { return false }
            return applyWorkspaceMutation(transition)
        } catch AppError.invalidLocalClock {
            reportInvalidLocalClock()
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func applyWorkspaceMutation(
        _ transition: SynchronizedWorkspaceMutationController.Transition
    ) -> Bool {
        timerState = transition.state
        if let output = transition.projection { installProjection(output) }
        for effect in transition.effects {
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
        case .alarm(let plan, let cancelReportsError):
            executeAlarmPlan(plan, cancelReportsError: cancelReportsError)
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
            ),
            cancelReportsError: false
        )
    }

    private func enqueueTaskOperation(_ type: TaskOperationType, task: FocusTask) -> Bool {
        performWorkspaceMutation(.task(type, task))
    }

    private func cancelAlarm(timerID: String, reportsError: Bool = true) {
        executeAlarmEffects([.cancel(
            timerID: timerID,
            reportsError: reportsError
        )])
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
        _ plan: TimerSessionController.AlarmPlan,
        cancelReportsError: Bool = true
    ) {
        executeAlarmEffects(alarmEffectCoordinator.effects(
            for: plan,
            cancelReportsError: cancelReportsError
        ))
    }

    private func executeAlarmEffects(_ effects: [AlarmEffectCoordinator.Effect]) {
        for effect in effects {
            switch effect {
            case .schedule(let timerID, let phase, let duration):
                enqueueAlarmOperation { [alarmScheduler] in
                    try await alarmScheduler.schedule(
                        timerID: timerID,
                        phase: phase,
                        duration: duration
                    )
                }
            case .pause(let timerID):
                enqueueAlarmOperation { [alarmScheduler] in
                    try await alarmScheduler.pause(timerID: timerID)
                }
            case .resume(let timerID, let phase, let duration):
                enqueueAlarmOperation { [alarmScheduler] in
                    try await alarmScheduler.resume(
                        timerID: timerID,
                        phase: phase,
                        duration: duration
                    )
                }
            case .cancel(let timerID, let reportsError):
                enqueueAlarmOperation(reportsError: reportsError) { [alarmScheduler] in
                    try await alarmScheduler.cancel(timerID: timerID)
                }
            }
        }
    }

    private func enqueueAlarmOperation(
        reportsError: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousOperation = alarmOperationTask
        alarmOperationTask = Task { [weak self] in
            await previousOperation?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                if reportsError {
                    self?.errorMessage = AlarmEffectCoordinator.errorMessage(for: error)
                }
            }
        }
    }

    @discardableResult
    private func rebuildOptimisticState() -> Bool {
        do {
            let output = try project(timerState)
            installProjection(output)
            return true
        } catch {
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
    }

    private func installUnreducedBaseSnapshot() {
        let publication = statePublisher.fallbackPublication(from: timerState)
        canonicalTimer = publication.canonicalTimer
        history = publication.history
        tasks = publication.tasks
        projectedAutoStartBreaks = publication.autoStartBreaks
        projectedSelectedTaskID = publication.selectedTaskID
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
        let request = accountSessionCoordinator.makeBootstrapResolutionRequest(
            strategy: strategy,
            snapshot: snapshot,
            state: timerState
        )
        timerState.pendingBootstrapResolution = request
        persist()
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
                deviceID: timerState.deviceId
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
        let sampledResponse = try await accountSessionCoordinator.sendBootstrapResolution(request)
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
        let projection = try project(resolved)
        let previousState = timerState
        timerState = resolved
        installProjection(projection)
        pruneLocalTimerOwners()
        guard persistAtomically(previous: previousState, rebuildsOnRollback: true) else {
            throw AppError.invalidResponse
        }
        applyCoordinatorPublication(accountSessionCoordinator.finishBootstrapResolution())
        errorMessage = nil
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
        applyPersistenceTransition(accountSessionCoordinator.persist(
            timerState,
            to: persistenceDestination(for: timerState)
        ))
    }

    @discardableResult
    private func persistAtomically(
        previous: PersistedTimerState,
        rebuildsOnRollback: Bool
    ) -> Bool {
        applyPersistenceTransition(accountSessionCoordinator.persistAtomically(
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
