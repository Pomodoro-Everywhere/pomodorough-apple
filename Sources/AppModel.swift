import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case restoring
        case localOnly
        case signedIn(User)
    }

    enum HistoryResolutionState: Equatable {
        case none
        case preflighting
        case choosing
        case confirming(BootstrapResolutionStrategy)
        case submitting(BootstrapResolutionStrategy)
        case retryable(BootstrapResolutionStrategy?)
    }

    private let api: APIClient
    private let defaults: UserDefaults
    private let roomStore: IrohRoomStore
    private let endpointKeyStore: any IrohEndpointKeyStoring
    private let alarmScheduler: any TimerAlarmScheduling
    private let googleIdentityProvider: any GoogleIdentityProviding
    private let retryDelay: Duration
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var timerState: PersistedTimerState
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var alarmOperationTask: Task<Void, Never>?
    @ObservationIgnored private var syncOwnership = SyncOwnership()
    @ObservationIgnored private var sessionVerification = SessionVerification()
    @ObservationIgnored private var sessionVerificationOwner: UUID?
    @ObservationIgnored private var revisionStreamTask: Task<Void, Never>?
    @ObservationIgnored private var remotePollingTask: Task<Void, Never>?
    @ObservationIgnored private var irohStartupTask: Task<Void, Never>?
    @ObservationIgnored private var revisionLifecycle = RevisionStreamLifecycle()
    @ObservationIgnored private var revisionHints = RevisionHintCoalescer()
    @ObservationIgnored private var completionQueuedFor: String?
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var replicationGeneration = 0
    @ObservationIgnored private var bootstrapSnapshot: BootstrapResponse?
    @ObservationIgnored private var physicalAnchor: (wall: Date, uptime: TimeInterval)?
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private lazy var irohService = IrohReplicationService(
        store: roomStore,
        keyStore: endpointKeyStore,
        statusHandler: { [weak self] status in self?.irohStatus = status },
        projectionHandler: { [weak self] roomID, state in self?.applyIrohProjection(state, roomID: roomID) }
    )

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
        roomStore: IrohRoomStore = IrohRoomStore(),
        endpointKeyStore: any IrohEndpointKeyStoring = IrohEndpointKeychainStore(),
        alarmScheduler: (any TimerAlarmScheduling)? = nil,
        googleIdentityProvider: any GoogleIdentityProviding = SystemGoogleIdentityProvider(),
        retryDelay: Duration = .seconds(5),
        now: @escaping () -> Date = { .now },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.api = api
        self.defaults = defaults
        self.roomStore = roomStore
        self.endpointKeyStore = endpointKeyStore
        self.alarmScheduler = alarmScheduler ?? TimerAlarmScheduler()
        self.googleIdentityProvider = googleIdentityProvider
        self.retryDelay = retryDelay
        self.now = now
        self.uptime = uptime
        var initialReplicationMode = defaults.string(forKey: Self.replicationModeKey)
            .flatMap(ReplicationMode.init(rawValue:)) ?? .centralized
        let initialWall = now()
        let initialUptime = uptime()
        if WireBounds.physicalMilliseconds(for: initialWall) != nil,
           initialUptime.isFinite,
           initialUptime >= 0 {
            physicalAnchor = (initialWall, initialUptime)
        }
        let storedData = defaults.data(forKey: Self.storageKey) ?? defaults.data(forKey: "timer-state")
        let decodedState = storedData.flatMap {
            try? JSONDecoder.api.decode(PersistedTimerState.self, from: $0)
        }
        var stagedState = decodedState ?? .fresh()
        if initialReplicationMode == .iroh, let roomState = roomStore.activeRoomState {
            stagedState = roomState
            if Self.advanceDefaultPhaseAfterIrohCompletion(in: &stagedState) {
                _ = try? roomStore.captureLocalOperations(from: stagedState)
            }
        } else if initialReplicationMode == .iroh {
            initialReplicationMode = .offline
            defaults.set(ReplicationMode.offline.rawValue, forKey: Self.replicationModeKey)
        }
        replicationMode = initialReplicationMode
        var migratedLegacyDurations = false
        var migratedLegacyAutoStartBreaks = false
        var migratedLegacySelectedTask = false
        var migratedLegacyTimerOwnership = false
        var migratedLegacyTasks = false
        var removesLegacyTasks = false
        var legacyMigrationFailed = false
        if let data = storedData, decodedState != nil {
            migratedLegacyDurations = !Self.hasPersistedDurationOperations(in: data)
            if migratedLegacyDurations {
                stagedState.migrateLegacyDurationSettings()
            }
            migratedLegacyAutoStartBreaks = !Self.hasPersistedAutoStartOperations(in: data)
            if migratedLegacyAutoStartBreaks {
                do {
                    let migrationDate = try stagedState.trustedOccurrenceDate(
                        for: initialWall,
                        uptime: initialUptime
                    )
                    try stagedState.migrateLegacyAutoStartBreaks(
                        explicitlySet: Self.hasExplicitLegacyAutoStartBreaks(in: data),
                        at: migrationDate
                    )
                } catch {
                    legacyMigrationFailed = true
                }
            }
            migratedLegacyTimerOwnership = stagedState.migrateLegacyTimerOwnership()
        }
        if let data = defaults.data(forKey: Self.localTaskStorageKey),
           let state = try? JSONDecoder.api.decode(LocalTaskState.self, from: data) {
            do {
                let migrationDate = try stagedState.trustedOccurrenceDate(
                    for: initialWall,
                    uptime: initialUptime
                )
                try stagedState.migrateLegacyTasks(state, at: migrationDate)
                migratedLegacyTasks = true
                removesLegacyTasks = true
            } catch {
                legacyMigrationFailed = true
            }
        }
        let hasPersistedSelectedTaskOperations = storedData.map(
            Self.hasPersistedSelectedTaskOperations(in:)
        ) ?? false
        if initialReplicationMode != .iroh,
           !hasPersistedSelectedTaskOperations {
            do {
                let migrationDate = try stagedState.trustedOccurrenceDate(
                    for: initialWall,
                    uptime: initialUptime
                )
                migratedLegacySelectedTask = try stagedState.migrateLegacySelectedTask(at: migrationDate)
            } catch {
                legacyMigrationFailed = true
            }
        }
        let stagedStateIsValid = stagedState.hasValidPendingWireOperations
        if !legacyMigrationFailed, stagedStateIsValid {
            timerState = stagedState
            if removesLegacyTasks {
                defaults.removeObject(forKey: Self.localTaskStorageKey)
            }
        } else {
            timerState = decodedState ?? .fresh()
        }
#if os(iOS) || os(macOS)
        needsPermissionIntroduction = !defaults.bool(forKey: Self.permissionIntroductionKey)
#endif
        rebuildOptimisticState()
        if let request = timerState.pendingBootstrapResolution {
            historyResolutionState = .retryable(request.strategy)
        } else if timerState.bootstrapUser != nil {
            historyResolutionState = .retryable(nil)
        }
        if !legacyMigrationFailed,
           stagedStateIsValid,
            migratedLegacyTasks
            || migratedLegacyDurations
            || migratedLegacyAutoStartBreaks
            || migratedLegacySelectedTask
            || migratedLegacyTimerOwnership {
            persist()
        } else if legacyMigrationFailed || !timerState.hasValidPendingWireOperations {
            reportInvalidLocalClock()
        }
    }

    deinit {
        retryTask?.cancel()
        alarmOperationTask?.cancel()
        revisionStreamTask?.cancel()
        remotePollingTask?.cancel()
        irohStartupTask?.cancel()
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
            guard !isWorkspaceMutationBlocked,
                  timerState.hasValidPendingWireOperations else {
                if !timerState.hasValidPendingWireOperations { reportInvalidLocalClock() }
                return
            }
            timerState.selectedPhaseGeneration = nextPhaseGeneration(
                after: timerState.selectedPhaseGeneration
            )
            timerState.settings.selectedPhase = newValue
            timerState.hasExplicitPhaseSelection = true
            persist()
        }
    }

    var selectedTaskID: UUID? {
        get { timerState.selectedTaskID }
        set {
            guard !isWorkspaceMutationBlocked,
                   timerState.hasValidPendingWireOperations,
                   newValue != timerState.selectedTaskID,
                   newValue == nil || tasks.contains(where: { $0.id == newValue }) else { return }
            let localDate = effectivePhysicalNow() ?? now()
            let occurredAt: Date
            do {
                occurredAt = try trustedOccurrenceDate(localDate: localDate)
            } catch {
                reportInvalidLocalClock()
                return
            }
            var updated = timerState
            do {
                try appendSelectedTaskOperation(newValue, at: occurredAt, to: &updated)
            } catch {
                reportInvalidLocalClock()
                return
            }
            timerState = updated
            guard persist() else { return }
            Task { await sync() }
        }
    }

    var autoStartBreaks: Bool {
        get {
            AutoStartReducer.applying(
                timerState.pendingAutoStartOperations,
                to: timerState.autoStartBreaks
            )
        }
        set {
            guard !isWorkspaceMutationBlocked, newValue != autoStartBreaks else { return }
            let now = effectivePhysicalNow() ?? now()
            let occurredAt: Date
            do {
                occurredAt = try trustedOccurrenceDate(localDate: now)
            } catch {
                reportInvalidLocalClock()
                return
            }
            var updated = timerState
            do {
                try updated.advanceClock(at: occurredAt)
                let operationID = try updated.reserveUuidV7()[0]
                updated.pendingAutoStartOperations.append(AutoStartOperation(
                    id: operationID,
                    deviceId: updated.deviceId,
                    enabled: newValue,
                    occurredAt: occurredAt,
                    hlcWallMs: updated.hlcWallMs,
                    hlcCounter: updated.hlcCounter
                ))
            } catch {
                reportInvalidLocalClock()
                return
            }
            timerState = updated
            guard persist() else { return }
            Task { await sync() }
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
    var activeRoom: IrohRoomSnapshot? { roomStore.activeSnapshot }
    var preferredRoom: IrohRoomSnapshot? {
        roomStore.preferredRoomID.flatMap(roomStore.roomSnapshot(roomID:))
    }
    var hasIrohRoom: Bool { preferredRoom != nil }
    var irohStatusLabel: String { irohStatus.label }
    var pendingAccountSwitchUser: User? { timerState.pendingAccountSwitchUser }
    var isWorkspaceMutationBlocked: Bool {
        isHistoryResolutionBlocking || pendingAccountSwitchUser != nil
    }
    var isHistoryResolutionBlocking: Bool {
        replicationMode == .centralized && (historyResolutionState != .none
            || timerState.bootstrapUser != nil
            || timerState.pendingBootstrapResolution != nil)
    }
    var completedFocusCount: Int { history.count { $0.status == "completed" && $0.phase == .focus } }
    var completedFocusCountToday: Int {
        Self.completedFocusCount(in: history, on: effectivePhysicalNow() ?? now())
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
        guard !isWorkspaceMutationBlocked else { return }
        if isTimerActive {
            selectedPhase = phase
            return
        }
        guard let timer = canonicalTimer else {
            selectedPhase = phase
            return
        }
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return
        }
        var updated = timerState
        do {
            _ = try appendCommand(
                .clear,
                timer: timer,
                elapsed: timer.elapsed(at: localDate),
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
            updated.settings.selectedPhase = phase
            updated.selectedPhaseGeneration = nextPhaseGeneration(
                after: updated.selectedPhaseGeneration
            )
            updated.hasExplicitPhaseSelection = true
        } catch {
            reportInvalidLocalClock()
            return
        }
        timerState = updated
        guard commitCommands() else { return }
        cancelAlarm(timerID: timer.id, reportsError: false)
    }

    func setDurationMinutes(_ minutes: Int, for phase: TimerPhase) {
        guard !isWorkspaceMutationBlocked else { return }
        let clamped = min(180, max(1, minutes))
        let durationMs = Int64(clamped) * 60_000
        guard timerState.settings.durationMs(for: phase) != durationMs else { return }
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return
        }
        var updated = timerState
        var clearedTimerID: String?
        do {
            if let timer = canonicalTimer, !isTimerActive {
                _ = try appendCommand(
                    .clear,
                    timer: timer,
                    elapsed: timer.elapsed(at: localDate),
                    at: occurredAt,
                    localDate: localDate,
                    to: &updated
                )
                clearedTimerID = timer.id
            }
            try updated.advanceClock(at: occurredAt)
            let operationID = try updated.reserveUuidV7()[0]
            updated.pendingDurationOperations.removeAll { $0.phase == phase }
            updated.pendingDurationOperations.append(DurationOperation(
                id: "duration-operation-\(operationID.uuidString.lowercased())",
                phase: phase,
                durationMs: durationMs,
                occurredAt: occurredAt,
                hlcWallMs: updated.hlcWallMs,
                hlcCounter: updated.hlcCounter
            ))
            updated.settings.setMinutes(clamped, for: phase)
        } catch {
            reportInvalidLocalClock()
            return
        }
        timerState = updated
        rebuildOptimisticState()
        guard persist() else { return }
        if let clearedTimerID {
            cancelAlarm(timerID: clearedTimerID, reportsError: false)
        }
        Task { await sync() }
    }

    @discardableResult
    func addTask(_ title: String) -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
        guard let task = FocusTask(title: title) else { return false }
        guard !tasks.contains(where: { $0.id == task.id }) else { return true }
        return enqueueTaskOperation(.upsert, task: task)
    }

    func deleteTask(id: UUID) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        _ = enqueueTaskOperation(.delete, task: task)
    }

    func task(forTimerID timerID: String) -> FocusTask? {
        let taskID = canonicalTimer.flatMap { $0.id == timerID ? $0.taskId : nil }
            ?? history.first(where: { $0.timerId == timerID })?.taskId
            ?? timerState.pendingCommands.first(where: { $0.timerId == timerID && $0.type == .start })?.taskId
        let uuid = taskID.flatMap(UUID.init(uuidString:)) ?? timerState.legacyTaskAssignments[timerID]
        guard let uuid else { return nil }
        return tasks.first(where: { $0.id == uuid })
            ?? timerState.knownTasks.first(where: { $0.id == uuid })
    }

    func taskSummaries(for date: Date = .now, calendar: Calendar = .current) -> [TaskDailySummary] {
        var totals: [UUID: (finished: Int, timeMs: Int64)] = [:]
        for item in history {
            guard item.phase == .focus,
                  item.status == "completed",
                  let completedAt = item.completedAt,
                  calendar.isDate(completedAt, inSameDayAs: date),
                  let uuid = item.taskId.flatMap(UUID.init(uuidString:))
                    ?? timerState.legacyTaskAssignments[item.timerId] else { continue }
            let current = totals[uuid] ?? (0, 0)
            totals[uuid] = (current.finished + 1, current.timeMs + item.plannedDurationMs)
        }
        return tasks.map { task in
            let total = totals[task.id] ?? (0, 0)
            return TaskDailySummary(
                task: task,
                finishedPomodoros: total.finished,
                timeSpentMs: total.timeMs
            )
        }
    }

    func completedFocusSummaries() -> [CompletedFocusSummary] {
        let taskByID = (timerState.knownTasks + tasks).reduce(into: [UUID: FocusTask]()) { lookup, task in
            lookup[task.id] = task
        }
        let legacyAssignments = timerState.legacyTaskAssignments
        return HistoryAnalytics.completedFocusSummaries(from: history, taskIDForItem: { item in
            item.taskId ?? legacyAssignments[item.timerId]?.uuidString
        }) { item in
            let taskID = item.taskId.flatMap(UUID.init(uuidString:)) ?? legacyAssignments[item.timerId]
            return taskID.flatMap { taskByID[$0] }
        }
    }

    func taskContext(for item: HistoryItem) -> String {
        let taskID = item.taskId.flatMap(UUID.init(uuidString:))
            ?? timerState.legacyTaskAssignments[item.timerId]
        let taskByID = (timerState.knownTasks + tasks).reduce(into: [UUID: FocusTask]()) { lookup, task in
            lookup[task.id] = task
        }
        return HistoryAnalytics.taskContext(for: item) { _ in
            taskID.flatMap { taskByID[$0] }
        }
    }

    func restore() async {
        guard sessionState == .restoring else { return }
        let generation = sessionGeneration
        do {
            guard try await api.restoreTokens() else {
                guard generation == sessionGeneration else { return }
                sessionState = .localOnly
                return
            }
            guard generation == sessionGeneration else { return }
            guard let cachedUser = timerState.cachedUser ?? timerState.bootstrapUser else {
                sessionGeneration += 1
                sessionVerification.invalidate()
                syncOwnership.invalidate()
                sessionState = .localOnly
                try? await api.clearTokens()
                return
            }
            sessionState = .signedIn(cachedUser)
            await verifyRestoredSession(generation: generation)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch {
            guard generation == sessionGeneration else { return }
            sessionState = .localOnly
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
        guard !isWorking else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        isWorking = true
        errorMessage = nil
        Task {
            defer {
                if generation == sessionGeneration { isWorking = false }
            }
            do {
                let challenge = try await api.challenge()
                let idToken = try await googleIdentityProvider.identityToken(nonce: challenge.nonce)
                let me = try await api.exchange(
                    NativeExchangeRequest(
                        idToken: idToken,
                        challenge: challenge.challenge,
                        deviceId: timerState.deviceId,
                        platform: Self.platform
                    )
                )
                guard generation == sessionGeneration else { return }
                sessionVerification.markVerified(generation: generation)
                sessionState = .signedIn(me.user)
                isOffline = false
                await completeAuthenticatedSession(user: me.user, generation: generation)
            } catch {
                guard generation == sessionGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmAccountSwitch() async {
        guard let authenticatedUser = timerState.pendingAccountSwitchUser,
              user?.id == authenticatedUser.id else { return }
        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id, reportsError: false)
        }
        var updated = timerState
        updated.prepare(for: authenticatedUser)
        guard let data = try? JSONEncoder.api.encode(updated) else {
            errorMessage = String(localized: "Account switch paused because local data could not be saved.")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        timerState = updated
        historyResolutionState = .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        rebuildOptimisticState()
        await sync(force: true)
    }

    func cancelAccountSwitch() async {
        guard timerState.pendingAccountSwitchUser != nil, !isWorking else { return }
        sessionGeneration += 1
        sessionState = .localOnly
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        googleIdentityProvider.signOut()
        timerState.pendingAccountSwitchUser = nil
        persist()
        isWorking = true
        defer { isWorking = false }
        do { try await api.logout() } catch { try? await api.clearTokens() }
    }

    func signOut() {
        guard !isWorking else { return }
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        if !preservesBootstrapResolution, let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id)
        }
        sessionGeneration += 1
        sessionState = .localOnly
        isOffline = false
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        historyResolutionState = preservesBootstrapResolution
            ? .retryable(timerState.pendingBootstrapResolution?.strategy)
            : .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        revisionHints = RevisionHintCoalescer()
        isWorking = true
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        googleIdentityProvider.signOut()
        if replicationMode == .iroh {
            timerState.cachedUser = nil
            timerState.bootstrapUser = nil
            timerState.pendingBootstrapResolution = nil
            var clearedReturnState = roomStore.activeReturnState ?? PersistedTimerState.fresh()
            if clearedReturnState.cachedUser != nil {
                let preservedDeviceID = clearedReturnState.deviceId
                clearedReturnState = .fresh()
                clearedReturnState.deviceId = preservedDeviceID
            } else {
                clearedReturnState.cachedUser = nil
                clearedReturnState.pendingAccountSwitchUser = nil
                clearedReturnState.bootstrapUser = nil
                clearedReturnState.pendingBootstrapResolution = nil
            }
            try? roomStore.replaceActiveReturnState(clearedReturnState)
            persist()
        } else if preservesBootstrapResolution {
            persist()
        } else {
            timerState = .fresh()
            rebuildOptimisticState()
            persist()
        }

        Task {
            defer { isWorking = false }
            do { try await api.logout() } catch { try? await api.clearTokens() }
        }
    }

    func deleteAccount(confirmation: String) async {
        guard confirmation == "DELETE", isSignedIn, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.deleteAccount(confirmation: confirmation)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if let timer = canonicalTimer {
            cancelAlarm(timerID: timer.id, reportsError: false)
        }
        sessionGeneration += 1
        sessionState = .localOnly
        isOffline = false
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isSyncing = false
        historyResolutionState = .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        googleIdentityProvider.signOut()
        timerState = .fresh()
        rebuildOptimisticState()
        persist()
    }

    @discardableResult
    func handleGoogleSignInURL(_ url: URL) -> Bool {
        googleIdentityProvider.handle(url)
    }

    func start() {
        guard !isWorkspaceMutationBlocked, !isTimerActive else { return }
        let timerID = "timer-\(UUID().uuidString.lowercased())"
        let phase = selectedPhase
        let duration = TimeInterval(timerState.settings.durationMs(for: phase)) / 1_000
        let taskID = phase == .focus
            ? timerState.selectedTaskID.flatMap { selected in
                tasks.first(where: { $0.id == selected })?.id.uuidString.lowercased()
            }
            : nil
        guard enqueue(
            .start,
            timerID: timerID,
            taskID: taskID,
            phase: phase,
            duration: duration,
            elapsed: 0
        ) else { return }
        timerState.hasExplicitPhaseSelection = false
        _ = persist()
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(timerID: timerID, phase: phase, duration: duration)
        }
    }

    func pause(at explicitDate: Date? = nil) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = canonicalTimer, timer.status == .running else { return }
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        guard enqueue(.pause, timer: timer, elapsed: timer.elapsed(at: date)) else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.pause(timerID: timer.id)
        }
    }

    func resume(at explicitDate: Date? = nil) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = canonicalTimer, timer.status == .paused else { return }
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        let remainingDuration = max(1, timer.remaining(at: date))
        guard enqueue(.resume, timer: timer, elapsed: timer.elapsed(at: date)) else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.resume(
                timerID: timer.id,
                phase: timer.phase,
                duration: remainingDuration
            )
        }
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
        timer explicitTimer: CanonicalTimer? = nil
    ) -> Bool {
        guard !isWorkspaceMutationBlocked else { return false }
        guard let timer = explicitTimer ?? canonicalTimer,
              timer.status == .running || timer.status == .paused else { return false }
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return false
        }
        var updated = timerState
        let finishCommand: TimerCommand
        do {
            finishCommand = try appendCommand(
                .finish,
                timer: timer,
                elapsed: timer.elapsed(at: date),
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
        } catch {
            reportInvalidLocalClock()
            return false
        }
        let nextPhase: TimerPhase
        if timer.phase == .focus {
            let projected = TimerReducer.applying(
                updated.localProjection(of: updated.pendingCommands),
                to: (try? updated.physicalCanonicalTimer(updated.canonicalTimer)) ?? updated.canonicalTimer,
                history: updated.history
            )
            let sourceCompletionDate = projected.history.first {
                $0.timerId == timer.id && $0.status == CanonicalTimer.Status.completed.rawValue
            }.flatMap { $0.completedAt ?? $0.endedAt } ?? date
            let completedFocusCount = Self.completedFocusCount(
                in: projected.history,
                on: sourceCompletionDate
            )
            nextPhase = TimerReducer.breakPhase(afterCompletedFocusCount: completedFocusCount)
        } else {
            nextPhase = .focus
        }
        let previousPhase = updated.settings.selectedPhase
        if !updated.hasExplicitPhaseSelection {
            updated.selectedPhaseGeneration = nextPhaseGeneration(
                after: updated.selectedPhaseGeneration
            )
            updated.settings.selectedPhase = nextPhase
        }
        if replicationMode == .centralized, !updated.hasExplicitPhaseSelection {
            updated.provisionalPhaseAdvances.append(ProvisionalPhaseAdvance(
                sourceTimerId: timer.id,
                finishCommandId: finishCommand.id,
                previousPhase: previousPhase,
                advancedPhase: nextPhase,
                generation: updated.selectedPhaseGeneration
            ))
        }

        guard timer.phase == .focus, autoStartBreaks else {
            timerState = updated
            guard commitCommands() else { return false }
            if cancelsAlarm {
                cancelAlarm(timerID: timer.id)
            }
            return true
        }

        let breakTimerID = "timer-\(UUID().uuidString.lowercased())"
        let breakDuration = TimeInterval(updated.settings.durationMs(for: nextPhase)) / 1_000
        if replicationMode == .iroh {
            timerState = updated
            guard commitCommands(),
                  history.contains(where: { $0.commandId == finishCommand.id && $0.status == "completed" }),
                  enqueue(
                      .start,
                      timerID: breakTimerID,
                      taskID: nil,
                      phase: nextPhase,
                      duration: breakDuration,
                      elapsed: 0
                  ) else { return false }
            if cancelsAlarm { cancelAlarm(timerID: timer.id) }
            enqueueAlarmOperation { [alarmScheduler] in
                try await alarmScheduler.schedule(
                    timerID: breakTimerID,
                    phase: nextPhase,
                    duration: breakDuration
                )
            }
            return true
        }
        let startCommand: TimerCommand
        do {
            startCommand = try appendCommand(
                .start,
                timerID: breakTimerID,
                taskID: nil,
                phase: nextPhase,
                duration: breakDuration,
                elapsed: 0,
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
        } catch {
            reportInvalidLocalClock()
            return false
        }
        updated.provisionalBreaks.append(ProvisionalBreak(
            focusTimerId: timer.id,
            finishCommandId: finishCommand.id,
            breakTimerId: breakTimerID,
            startCommandId: startCommand.id
        ))
        timerState = updated
        guard commitCommands() else { return false }
        if cancelsAlarm {
            cancelAlarm(timerID: timer.id)
        }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(
                timerID: breakTimerID,
                phase: nextPhase,
                duration: breakDuration
            )
        }
        return true
    }

    func cancel(at explicitDate: Date? = nil) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = canonicalTimer,
              timer.status == .running || timer.status == .paused else { return }
        let date = explicitDate ?? effectivePhysicalNow() ?? now()
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return
        }
        let elapsed = timer.elapsed(at: date)
        var updated = timerState
        do {
            _ = try appendCommand(
                .cancel,
                timer: timer,
                elapsed: elapsed,
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
            _ = try appendCommand(
                .clear,
                timer: timer,
                elapsed: elapsed,
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
        } catch {
            reportInvalidLocalClock()
            return
        }
        timerState = updated
        guard commitCommands() else { return }
        cancelAlarm(timerID: timer.id)
    }

    func clear() {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = canonicalTimer, !isTimerActive else { return }
        let date = effectivePhysicalNow() ?? now()
        guard enqueue(.clear, timer: timer, elapsed: timer.elapsed(at: date)) else { return }
        if completionAlertTimerID == timer.id {
            completionAlertTimerID = nil
        }
        cancelAlarm(timerID: timer.id, reportsError: false)
    }

    func stopSound() {
        guard !isWorkspaceMutationBlocked else { return }
        let alertTimerID = completionAlertTimerID
        completionAlertTimerID = nil
        if let alertTimerID {
            cancelAlarm(timerID: alertTimerID, reportsError: false)
        }
        guard let timer = canonicalTimer, !isTimerActive else { return }
        let date = effectivePhysicalNow() ?? now()
        guard enqueue(.clear, timer: timer, elapsed: timer.elapsed(at: date)) else { return }
        if timer.id != alertTimerID {
            cancelAlarm(timerID: timer.id, reportsError: false)
        }
    }

    func completeIfNeeded(timerID: String, at date: Date) {
        guard !isWorkspaceMutationBlocked else { return }
        guard let timer = durableIrohTimerNeedingCompletion ?? canonicalTimer,
              timer.id == timerID,
              timer.status == .running,
              timer.remaining(at: date) <= 0,
              ownsAutomaticCompletion(for: timer.id),
              completionQueuedFor != timer.id else { return }
        if replicationMode == .iroh {
            completeIrohTimerIfNeeded(timer, at: date)
            return
        }
        if finish(at: date, cancelsAlarm: false, timer: timer) {
            completionAlertTimerID = timer.id
            stopCompletionAlertIfTimerStarted()
            completionQueuedFor = canonicalTimer?.status == .running ? timer.id : nil
        }
    }

    private func completeIrohTimerIfNeeded(_ timer: CanonicalTimer, at date: Date) {
        let projected = TimerReducer.projectingTimeCompletion(
            timer,
            history: timerState.history,
            at: date
        )
        guard projected.timer?.status == .completed else { return }
        let nextPhase = timer.phase == .focus
            ? TimerReducer.breakPhase(afterCompletedFocusCount: projected.history.count {
                $0.status == CanonicalTimer.Status.completed.rawValue && $0.phase == .focus
            })
            : .focus
        var updated = timerState
        if !updated.hasExplicitPhaseSelection {
            updated.settings.selectedPhase = nextPhase
        }

        guard timer.phase == .focus, autoStartBreaks else {
            timerState = updated
            rebuildOptimisticState()
            _ = persist()
            completionAlertTimerID = timer.id
            stopCompletionAlertIfTimerStarted()
            return
        }

        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return
        }
        guard let completedAt = projected.timer?.anchorAt, occurredAt >= completedAt else { return }
        let breakTimerID = "timer-\(UUID().uuidString.lowercased())"
        let breakDuration = TimeInterval(updated.settings.durationMs(for: nextPhase)) / 1_000
        do {
            try appendCommand(
                .start,
                timerID: breakTimerID,
                taskID: nil,
                phase: nextPhase,
                duration: breakDuration,
                elapsed: 0,
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
        } catch {
            reportInvalidLocalClock()
            return
        }
        timerState = updated
        guard commitCommands() else { return }
        completionAlertTimerID = timer.id
        stopCompletionAlertIfTimerStarted()
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(
                timerID: breakTimerID,
                phase: nextPhase,
                duration: breakDuration
            )
        }
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
        guard historyResolutionState == .choosing else { return }
        historyResolutionState = .confirming(strategy)
    }

    func cancelHistoryResolutionConfirmation() {
        guard case .confirming = historyResolutionState else { return }
        historyResolutionState = .choosing
    }

    func confirmHistoryResolution() async {
        guard case .confirming(let strategy) = historyResolutionState,
              let snapshot = bootstrapSnapshot else { return }
        await submitBootstrapResolution(strategy: strategy, snapshot: snapshot)
    }

    func retryHistoryResolution() async {
        guard case .retryable = historyResolutionState else { return }
        guard isSignedIn else {
            signIn()
            return
        }
        let generation = sessionGeneration
        guard sessionVerification.allows(generation: generation) else {
            await verifyRestoredSession(generation: generation)
            return
        }
        if let request = timerState.pendingBootstrapResolution {
            await submitPersistedBootstrapResolution(request, generation: generation)
        } else {
            await preflightBootstrapResolution(generation: generation)
        }
    }

    func sync(force: Bool = false, showsActivity: Bool = true) async {
        guard replicationMode == .centralized, isSignedIn, !isWorkspaceMutationBlocked else { return }
        let generation = sessionGeneration
        let modeGeneration = replicationGeneration
        guard sessionVerification.allows(generation: generation) else {
            await verifyRestoredSession(generation: generation)
            return
        }
        guard timerState.cachedUser?.id == user?.id else { return }
        guard timerState.hasValidPendingWireOperationsForResample else {
            reportInvalidPendingOperations()
            return
        }
        if !force,
           timerState.pendingCommands.isEmpty,
           timerState.pendingTaskOperations.isEmpty,
           timerState.pendingDurationOperations.isEmpty,
           timerState.pendingAutoStartOperations.isEmpty,
           timerState.pendingSelectedTaskOperations.isEmpty { return }
        guard let syncID = syncOwnership.begin(generation: generation) else { return }
        var allowsFollowUpSync = true
        retryTask?.cancel()
        if showsActivity { isSyncing = true }
        defer {
            if let requestedFollowUp = syncOwnership.finish(syncID, currentGeneration: sessionGeneration) {
                if showsActivity { isSyncing = false }
                let hintedFollowUp = revisionHints.consumeFollowUp(localRevision: timerState.revision)
                let hasPendingOperations = !timerState.pendingCommands.isEmpty
                    || !timerState.pendingTaskOperations.isEmpty
                    || !timerState.pendingDurationOperations.isEmpty
                    || !timerState.pendingAutoStartOperations.isEmpty
                    || !timerState.pendingSelectedTaskOperations.isEmpty
                let needsLocalFollowUp = requestedFollowUp && hasPendingOperations
                let needsRemoteFollowUp = generation == sessionGeneration
                    && modeGeneration == replicationGeneration
                    && replicationMode == .centralized
                    && hintedFollowUp
                if allowsFollowUpSync,
                   modeGeneration == replicationGeneration,
                   replicationMode == .centralized,
                   isSignedIn,
                   (needsLocalFollowUp || needsRemoteFollowUp) {
                    Task { [weak self] in await self?.sync(force: true) }
                }
            }
        }
        do {
            repeat {
                let batch = uploadableCommands(limit: 256)
                let taskBatch = Array(timerState.pendingTaskOperations.prefix(256))
                let durationBatch = Array(timerState.pendingDurationOperations.prefix(256))
                let autoStartBatch = Array(timerState.pendingAutoStartOperations.prefix(256))
                let selectedTaskBatch = Array(timerState.pendingSelectedTaskOperations.prefix(256))
                guard !batch.isEmpty || timerState.pendingCommands.isEmpty else {
                    throw AppError.invalidResponse
                }
                let previousTimer = activeTimer
                let sampledResponse = try await api.sync(
                    SyncRequest(
                        deviceId: timerState.deviceId,
                        lastRevision: timerState.revision,
                        commands: batch,
                        taskOperations: taskBatch,
                        durationOperations: durationBatch,
                        autoStartOperations: autoStartBatch,
                        selectedTaskOperations: selectedTaskBatch
                    )
                )
                let response = sampledResponse.value
                let receivedAt = effectivePhysicalNow() ?? now()
                guard generation == sessionGeneration,
                      modeGeneration == replicationGeneration,
                      replicationMode == .centralized,
                      isSignedIn else { return }
                guard response.hasValidCanonicalSnapshot,
                      WireBounds.containsUnsigned(response.revision),
                      response.revision >= timerState.revision else {
                    throw AppError.invalidResponse
                }

                let sentIDs = batch.map(\.id)
                let acknowledgedIDs = response.acknowledgements.map(\.commandId)
                guard AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: acknowledgedIDs) else {
                    throw AppError.invalidResponse
                }
                let sentTaskIDs = taskBatch.map(\.id)
                let acknowledgedTaskIDs = response.taskAcknowledgements.map(\.operationId)
                guard AcknowledgementSet.exactlyMatches(sent: sentTaskIDs, acknowledged: acknowledgedTaskIDs) else {
                    throw AppError.invalidResponse
                }
                var syncedState = timerState
                try syncedState.mergeClock(
                    serverWallMs: response.serverHlcWallMs,
                    serverCounter: response.serverHlcCounter,
                    serverTime: response.serverTime,
                    requestWall: sampledResponse.requestWall,
                    requestUptime: sampledResponse.requestUptime,
                    responseUptime: sampledResponse.responseUptime
                )
                try syncedState.applyDurationSync(
                    canonicalDurations: response.durationsMs,
                    sentOperations: durationBatch,
                    acknowledgements: response.durationAcknowledgements
                )
                try syncedState.applyAutoStartSync(
                    canonicalValue: response.autoStartBreaks,
                    sentOperations: autoStartBatch,
                    acknowledgements: response.autoStartAcknowledgements
                )
                try syncedState.applySelectedTaskSync(
                    canonicalTaskId: response.selectedTaskId,
                    canonicalTasks: response.tasks,
                    sentOperations: selectedTaskBatch,
                    acknowledgements: response.selectedTaskAcknowledgements
                )
                resolveProvisionalBreaks(
                    in: &syncedState,
                    acknowledgements: response.acknowledgements,
                    canonicalHistory: response.history,
                    canonicalTimer: response.canonicalTimer
                )
                resolveProvisionalPhaseAdvances(
                    in: &syncedState,
                    acknowledgements: response.acknowledgements,
                    canonicalHistory: response.history,
                    canonicalTimer: response.canonicalTimer
                )
                updateLocalTimerOwnership(
                    in: &syncedState,
                    sentCommands: batch,
                    acknowledgements: response.acknowledgements,
                    canonicalTimer: response.canonicalTimer,
                    canonicalHistory: response.history
                )
                let acknowledgedIDSet = Set(acknowledgedIDs)
                let acknowledgedTaskIDSet = Set(acknowledgedTaskIDs)
                syncedState.pendingCommands.removeAll { acknowledgedIDSet.contains($0.id) }
                syncedState.pendingTaskOperations.removeAll { acknowledgedTaskIDSet.contains($0.id) }
                try syncedState.rebasePendingOperations(
                    afterServerWallMs: response.serverHlcWallMs,
                    serverCounter: response.serverHlcCounter,
                    serverTime: response.serverTime
                )
                if let conflict = response.acknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty ? String(localized: "Server resolved a timer action as \(conflict.outcome.rawValue).") : conflict.reason
                } else if let conflict = response.taskAcknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty ? String(localized: "Server resolved a task change as \(conflict.outcome.rawValue).") : conflict.reason
                } else if let conflict = response.durationAcknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty ? String(localized: "Server resolved a duration change as \(conflict.outcome.rawValue).") : conflict.reason
                } else if let conflict = response.autoStartAcknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty
                        ? String(localized: "Server resolved an auto-start change as \(conflict.outcome.rawValue).")
                        : conflict.reason
                } else if let conflict = response.selectedTaskAcknowledgements.first(where: { $0.outcome != .applied }) {
                    conflictMessage = conflict.reason.isEmpty
                        ? String(localized: "Server resolved a selected-task change as \(conflict.outcome.rawValue).")
                        : conflict.reason
                }
                syncedState.revision = response.revision
                syncedState.canonicalTimer = response.canonicalTimer
                syncedState.migrateLegacyTimerOwnership()
                syncedState.history = response.history
                syncedState.tasks = response.tasks
                syncedState.mergeKnownTasks(response.tasks)
                syncedState.pruneLocalCommandDates()
                timerState = syncedState
                rebuildOptimisticState()
                pruneLocalTimerOwners()
                reconcileAlarm(from: previousTimer, to: activeTimer, at: receivedAt)
                isOffline = false
                errorMessage = nil
                persist()
            } while !timerState.pendingCommands.isEmpty
                || !timerState.pendingTaskOperations.isEmpty
                || !timerState.pendingDurationOperations.isEmpty
                || !timerState.pendingAutoStartOperations.isEmpty
                || !timerState.pendingSelectedTaskOperations.isEmpty
            startRevisionStream()
            startRemotePolling()
        } catch AppError.unauthorized {
            guard modeGeneration == replicationGeneration,
                  replicationMode == .centralized else { return }
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.invalidResponse, AppError.invalidLocalClock {
            guard generation == sessionGeneration,
                  modeGeneration == replicationGeneration,
                  replicationMode == .centralized,
                  isSignedIn else { return }
            allowsFollowUpSync = false
            isOffline = false
            errorMessage = String(localized: "Sync paused because the server response did not match queued changes. \(pendingChangeCount) queued changes remain on this device.")
            cancelRevisionStream()
        } catch {
            guard generation == sessionGeneration,
                  modeGeneration == replicationGeneration,
                  replicationMode == .centralized,
                  isSignedIn else { return }
            isOffline = true
            scheduleRetry()
        }
    }

    func refreshAfterForeground() async {
        completionQueuedFor = nil
        if replicationMode == .iroh {
            await startIrohIfNeeded()
            await irohService.syncNow()
            return
        }
        guard replicationMode == .centralized, isSignedIn else { return }
        if !isWorkspaceMutationBlocked {
            startRevisionStream()
            startRemotePolling()
        }
        await sync(force: true)
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        revisionLifecycle.setActive(active)
        if !active {
            revisionStreamTask?.cancel()
            revisionStreamTask = nil
            remotePollingTask?.cancel()
            remotePollingTask = nil
        }
        if replicationMode == .iroh {
            Task { [irohService] in
#if os(iOS)
                if active {
                    await startIrohIfNeeded()
                } else {
                    await irohService.stop()
                }
#else
                await startIrohIfNeeded()
#endif
            }
        }
    }

    func setReplicationMode(_ mode: ReplicationMode) async {
        guard mode != replicationMode else {
            if mode == .iroh { scheduleIrohStartup() }
            return
        }
        irohStartupTask?.cancel()
        irohStartupTask = nil
        errorMessage = nil
        roomInvite = nil
        let resumesCentralizedReplication = replicationMode == .centralized && mode != .centralized
        if resumesCentralizedReplication {
            quiesceCentralizedReplication()
        }
        if replicationMode == .iroh {
            await irohService.stop()
            do {
                timerState = try roomStore.captureAndSuspendActiveRoom(from: timerState)
            } catch {
                await startIrohIfNeeded()
                if resumesCentralizedReplication { resumeCentralizedReplication() }
                errorMessage = error.localizedDescription
                return
            }
        }
        if mode == .iroh {
            guard let roomID = roomStore.preferredRoomID else {
                if resumesCentralizedReplication { resumeCentralizedReplication() }
                errorMessage = String(localized: "Create or join an Iroh room before selecting Iroh mode.")
                return
            }
            do {
                timerState = try roomStore.activateExistingRoom(roomID: roomID, returnState: timerState)
            } catch {
                if resumesCentralizedReplication { resumeCentralizedReplication() }
                errorMessage = error.localizedDescription
                return
            }
            cancelRevisionStream()
        }
        if mode != .centralized { cancelRevisionStream() }
        replicationMode = mode
        defaults.set(mode.rawValue, forKey: Self.replicationModeKey)
        rebuildOptimisticState()
        persist()
        if mode == .centralized {
            if let user {
                await completeAuthenticatedSession(user: user, generation: sessionGeneration)
            }
        } else if mode == .iroh {
            scheduleIrohStartup()
        }
    }

    func createIrohRoom(name rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= 64 else {
            errorMessage = String(localized: "Room name must be 64 characters or fewer.")
            return false
        }
        let resumesCentralizedReplication = replicationMode == .centralized
        if resumesCentralizedReplication { quiesceCentralizedReplication() }
        do {
            let secret = secureRandomBytes(count: 32)
            let roomID = try IrohProtocolV1.roomID(for: secret)
            let context = irohContext(roomID: roomID, secret: secret)
            let ticket = try await irohService.start(context)
            let returnState = activeRoom?.conflict != nil
                ? roomStore.activeReturnState ?? timerState
                : timerState
            let genesis = IrohGenesis(
                canonicalTimer: canonicalTimer,
                history: history,
                tasks: tasks,
                durationsMs: timerState.settings.durationsMs,
                autoStartBreaks: autoStartBreaks,
                selectedTaskId: timerState.selectedTaskID?.uuidString.lowercased(),
                hlcWallMs: timerState.hlcWallMs,
                hlcCounter: timerState.hlcCounter
            )
            timerState = try roomStore.createRoom(
                roomID: roomID,
                roomSecret: secret,
                name: name.isEmpty ? nil : name,
                returnState: returnState,
                genesis: genesis
            )
            replicationMode = .iroh
            defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
            cancelRevisionStream()
            rebuildOptimisticState()
            roomInvite = try IrohRoomInvite(
                roomID: roomID,
                roomName: name.isEmpty ? nil : name,
                endpointTicket: ticket,
                roomSecret: secret
            ).encoded()
            irohStatus = .listening(endpointMark: String(ticket.suffix(6)))
            errorMessage = nil
            return true
        } catch {
            await irohService.stop()
            if resumesCentralizedReplication { resumeCentralizedReplication() }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshIrohInvite() async {
        guard let room = activeRoom, let secret = roomStore.activeRoomSecret else { return }
        do {
            await startIrohIfNeeded()
            let ticket = try await irohService.currentEndpointTicket()
            roomInvite = try IrohRoomInvite(
                roomID: room.roomID,
                roomName: room.roomName,
                endpointTicket: ticket,
                roomSecret: secret
            ).encoded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func joinIrohRoom(inviteText: String) async -> Bool {
        var preparedRoomID: String?
        let resumesCentralizedReplication = replicationMode == .centralized
        if resumesCentralizedReplication { quiesceCentralizedReplication() }
        do {
            let invite = try IrohRoomInvite.decode(inviteText.trimmingCharacters(in: .whitespacesAndNewlines))
            try roomStore.prepareJoinedRoom(
                roomID: invite.roomID,
                roomSecret: invite.roomSecret,
                name: invite.roomName,
                returnState: timerState,
                initialPeer: IrohPeer(
                    endpointID: invite.endpointID,
                    endpointTicket: invite.endpointTicket,
                    deviceID: nil,
                    displayName: nil,
                    lastSeenAt: nil
                )
            )
            preparedRoomID = invite.roomID
            _ = try await irohService.start(irohContext(roomID: invite.roomID, secret: invite.roomSecret))
            try await irohService.join(invite: invite)
            timerState = try roomStore.activateJoinedRoom(roomID: invite.roomID, returnState: timerState)
            replicationMode = .iroh
            defaults.set(ReplicationMode.iroh.rawValue, forKey: Self.replicationModeKey)
            cancelRevisionStream()
            rebuildOptimisticState()
            roomInvite = nil
            errorMessage = nil
            return true
        } catch {
            await irohService.stop()
            if let preparedRoomID {
                try? roomStore.discardUnconflictedInactiveRoom(roomID: preparedRoomID)
            }
            if resumesCentralizedReplication { resumeCentralizedReplication() }
            if replicationMode == .iroh { await startIrohIfNeeded() }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func requestIrohRoomLeave() {
        guard replicationMode == .iroh, !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = true
    }

    func cancelIrohRoomLeave() {
        guard !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = false
    }

    func confirmIrohRoomLeave() async {
        guard replicationMode == .iroh,
              isIrohRoomLeaveConfirmationPresented,
              !isLeavingIrohRoom else { return }
        isIrohRoomLeaveConfirmationPresented = false
        isLeavingIrohRoom = true
        defer { isLeavingIrohRoom = false }
        await irohService.stop()
        do {
            timerState = try roomStore.captureAndSuspendActiveRoom(from: timerState)
            replicationMode = .offline
            defaults.set(ReplicationMode.offline.rawValue, forKey: Self.replicationModeKey)
            roomInvite = nil
            rebuildOptimisticState()
            persist()
        } catch {
            await startIrohIfNeeded()
            errorMessage = error.localizedDescription
        }
    }

    func syncIrohNow() async {
        guard replicationMode == .iroh else { return }
        await startIrohIfNeeded()
        await irohService.syncNow()
    }

    private func cancelRevisionStream() {
        revisionLifecycle.cancelCurrent()
        revisionStreamTask?.cancel()
        revisionStreamTask = nil
        remotePollingTask?.cancel()
        remotePollingTask = nil
    }

    private func quiesceCentralizedReplication() {
        replicationGeneration += 1
        syncOwnership.invalidate()
        retryTask?.cancel()
        retryTask = nil
        isSyncing = false
        cancelRevisionStream()
    }

    private func resumeCentralizedReplication() {
        guard replicationMode == .centralized, isSignedIn else { return }
        startRevisionStream()
        startRemotePolling()
        Task { [weak self] in await self?.sync(force: true) }
    }

    private func ownsCentralizedReplication(generation: Int, modeGeneration: Int) -> Bool {
        generation == sessionGeneration
            && modeGeneration == replicationGeneration
            && replicationMode == .centralized
    }

    func nextBreakPhase() -> TimerPhase {
        TimerReducer.breakPhase(afterCompletedFocusCount: completedFocusCountToday)
    }

    private func enqueue(_ type: CommandType, timer: CanonicalTimer, elapsed: TimeInterval) -> Bool {
        enqueue(
            type,
            timerID: timer.id,
            taskID: nil,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed
        )
    }

    private func enqueue(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) -> Bool {
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return false
        }
        var updated = timerState
        do {
            _ = try appendCommand(
                type,
                timerID: timerID,
                taskID: taskID,
                phase: phase,
                duration: duration,
                elapsed: elapsed,
                at: occurredAt,
                localDate: localDate,
                to: &updated
            )
        } catch {
            reportInvalidLocalClock()
            return false
        }
        timerState = updated
        return commitCommands()
    }

    @discardableResult
    private func appendCommand(
        _ type: CommandType,
        timerID: String,
        taskID: String?,
        phase: TimerPhase,
        duration: TimeInterval,
        elapsed: TimeInterval,
        at occurredAt: Date,
        localDate: Date,
        to state: inout PersistedTimerState
    ) throws -> TimerCommand {
        try state.advanceClock(at: occurredAt)
        let sequence = try state.reserveDeviceSequence()
        let commandID = try state.reserveUuidV7()[0]
        let command = TimerCommand(
            id: "command-\(commandID.uuidString.lowercased())",
            deviceSequence: sequence,
            timerId: timerID,
            taskId: type == .start ? taskID : nil,
            type: type,
            phase: phase,
            plannedDurationMs: Int64(duration * 1_000),
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter,
            observedElapsedMs: Int64(max(0, elapsed) * 1_000)
        )
        state.pendingCommands.append(command)
        state.localCommandDates[command.id] = localDate
        if type == .start {
            state.localTimerOwners[timerID] = state.deviceId
        }
        return command
    }

    @discardableResult
    private func appendCommand(
        _ type: CommandType,
        timer: CanonicalTimer,
        elapsed: TimeInterval,
        at occurredAt: Date,
        localDate: Date,
        to state: inout PersistedTimerState
    ) throws -> TimerCommand {
        try appendCommand(
            type,
            timerID: timer.id,
            taskID: nil,
            phase: timer.phase,
            duration: timer.plannedDuration,
            elapsed: elapsed,
            at: occurredAt,
            localDate: localDate,
            to: &state
        )
    }

    @discardableResult
    private func commitCommands() -> Bool {
        rebuildOptimisticState()
        guard persist() else { return false }
        Task { await sync() }
        return true
    }

    private func uploadableCommands(limit: Int? = nil) -> [TimerCommand] {
        let provisionalTimerIDs = Set(timerState.provisionalBreaks.map(\.breakTimerId))
        let commands = timerState.pendingCommands.prefix {
            !provisionalTimerIDs.contains($0.timerId)
        }
        guard let limit else { return Array(commands) }
        return Array(commands.prefix(limit))
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
              timer.status == .running || timer.status == .paused,
              timer.remaining(at: effectivePhysicalNow() ?? now()) <= 0,
              ownsAutomaticCompletion(for: timer.id) else { return nil }
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

    private func resolveProvisionalBreaks(
        in state: inout PersistedTimerState,
        acknowledgements: [Acknowledgement],
        canonicalHistory: [HistoryItem],
        canonicalTimer: CanonicalTimer?
    ) {
        let acknowledgementsByID = Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) })
        var unresolved: [ProvisionalBreak] = []

        for provisional in state.provisionalBreaks {
            guard let acknowledgement = acknowledgementsByID[provisional.finishCommandId] else {
                unresolved.append(provisional)
                continue
            }
            let canonicalHistoryItem = canonicalHistory.first {
                $0.status == CanonicalTimer.Status.completed.rawValue
                    && $0.phase == .focus
                    && $0.timerId == provisional.focusTimerId
                    && $0.commandId == provisional.finishCommandId
            }
            let canonicalHistoryFinish = canonicalHistoryItem != nil
            let canonicalTimerFinish = canonicalTimer.map {
                $0.id == provisional.focusTimerId
                    && $0.phase == .focus
                    && $0.status == .completed
                    && $0.lastIntent?.type == .finish
                    && $0.lastIntent?.commandId == provisional.finishCommandId
            } ?? false
            let canonicalFinish = canonicalHistoryFinish || canonicalTimerFinish
            let canonicalSupersedesBreak = canonicalTimer.map {
                ($0.status == .running || $0.status == .paused)
                    && $0.id != provisional.focusTimerId
                    && $0.id != provisional.breakTimerId
            } ?? false
            guard acknowledgement.outcome != .rejected,
                  canonicalFinish,
                  !canonicalSupersedesBreak else {
                if let startIndex = state.pendingCommands.firstIndex(where: {
                    $0.id == provisional.startCommandId
                }) {
                    let dependencyEnd = state.pendingCommands[(startIndex + 1)...].firstIndex {
                        $0.type == .start
                    } ?? state.pendingCommands.endIndex
                    state.pendingCommands.removeSubrange(startIndex..<dependencyEnd)
                    state.localTimerOwners.removeValue(forKey: provisional.breakTimerId)
                } else {
                    state.localTimerOwners.removeValue(forKey: provisional.breakTimerId)
                }
                continue
            }

            let sourceDate = canonicalHistoryItem.flatMap { $0.completedAt ?? $0.endedAt }
                ?? (canonicalTimerFinish ? canonicalTimer?.anchorAt : nil)
                ?? state.localCommandDates[provisional.finishCommandId]
                ?? state.pendingCommands.first { $0.id == provisional.finishCommandId }?.occurredAt
                ?? now()
            let breakPhase = Self.canonicalBreakPhase(
                for: provisional,
                history: canonicalHistory,
                sourceDate: sourceDate
            )
            let breakDurationMs = state.settings.durationMs(for: breakPhase)
            if let startIndex = state.pendingCommands.firstIndex(where: {
                $0.id == provisional.startCommandId
            }) {
                let dependencyEnd = state.pendingCommands[(startIndex + 1)...].firstIndex {
                    $0.type == .start
                } ?? state.pendingCommands.endIndex
                let generatedBreakCompleted = state.pendingCommands[
                    startIndex..<dependencyEnd
                ].contains {
                    $0.timerId == provisional.breakTimerId
                        && $0.type == .finish
                }
                if !generatedBreakCompleted {
                    for index in startIndex..<dependencyEnd {
                        let command = state.pendingCommands[index]
                        guard command.timerId == provisional.breakTimerId else {
                            continue
                        }
                        state.pendingCommands[index] = TimerCommand(
                            id: command.id,
                            deviceSequence: command.deviceSequence,
                            timerId: command.timerId,
                            taskId: command.taskId,
                            type: command.type,
                            phase: breakPhase,
                            plannedDurationMs: breakDurationMs,
                            occurredAt: command.occurredAt,
                            hlcWallMs: command.hlcWallMs,
                            hlcCounter: command.hlcCounter,
                            observedElapsedMs: min(
                                command.observedElapsedMs,
                                breakDurationMs
                            )
                        )
                    }
                    if !state.hasExplicitPhaseSelection {
                        state.settings.selectedPhase = breakPhase
                    }
                }
            }
        }

        let pendingCommandIDs = Set(state.pendingCommands.map(\.id))
        state.provisionalBreaks = unresolved.filter {
            pendingCommandIDs.contains($0.startCommandId)
        }
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
            let canonicalHistoryFinish = canonicalHistory.contains {
                $0.timerId == provisional.sourceTimerId
                    && $0.commandId == provisional.finishCommandId
                    && $0.status == CanonicalTimer.Status.completed.rawValue
            }
            let canonicalTimerFinish = canonicalTimer.map {
                $0.id == provisional.sourceTimerId
                    && $0.status == .completed
                    && $0.lastIntent?.type == .finish
                    && $0.lastIntent?.commandId == provisional.finishCommandId
            } ?? false
            return acknowledgement.outcome == .rejected
                || (!canonicalHistoryFinish && !canonicalTimerFinish)
        }

        var unresolvedReversed: [ProvisionalPhaseAdvance] = []
        for index in advances.indices.reversed() {
            let provisional = advances[index]
            let invalidatedByDependency = earliestInvalidIndex.map { index >= $0 } ?? false
            let acknowledgement = acknowledgementsByID[provisional.finishCommandId]
            let shouldResolve = invalidatedByDependency || acknowledgement != nil
            guard shouldResolve else {
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

    private func nextPhaseGeneration(after generation: Int64) -> Int64 {
        generation == .max ? 0 : generation + 1
    }

    private static func canonicalBreakPhase(
        for provisional: ProvisionalBreak,
        history: [HistoryItem],
        sourceDate: Date
    ) -> TimerPhase {
        let completedFocuses = history.filter {
            $0.status == CanonicalTimer.Status.completed.rawValue
                && $0.phase == .focus
                && ($0.completedAt ?? $0.endedAt).map {
                    Calendar.current.isDate($0, inSameDayAs: sourceDate)
                } == true
        }.sorted {
            let lhsDate = $0.completedAt ?? .distantPast
            let rhsDate = $1.completedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return ($0.commandId ?? "") < ($1.commandId ?? "")
        }
        let sourceIndex = completedFocuses.firstIndex {
            $0.commandId == provisional.finishCommandId || $0.timerId == provisional.focusTimerId
        }
        return TimerReducer.breakPhase(
            afterCompletedFocusCount: sourceIndex.map { $0 + 1 } ?? completedFocuses.count + 1
        )
    }

    private static func completedFocusCount(
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

    private func updateLocalTimerOwnership(
        in state: inout PersistedTimerState,
        sentCommands: [TimerCommand],
        acknowledgements: [Acknowledgement],
        canonicalTimer: CanonicalTimer?,
        canonicalHistory: [HistoryItem]
    ) {
        let acknowledgementsByID = Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.commandId, $0) })
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

    private func reconcileAlarm(
        from previousTimer: CanonicalTimer?,
        to currentTimer: CanonicalTimer?,
        at date: Date
    ) {
        guard let previousTimer else {
            guard let currentTimer,
                  currentTimer.status == .running,
                  ownsAutomaticCompletion(for: currentTimer.id) else { return }
            enqueueAlarmOperation { [alarmScheduler] in
                try await alarmScheduler.schedule(
                    timerID: currentTimer.id,
                    phase: currentTimer.phase,
                    duration: max(1, currentTimer.remaining(at: date))
                )
            }
            return
        }
        guard previousTimer.status == .running || previousTimer.status == .paused else { return }
        guard let currentTimer,
              currentTimer.id == previousTimer.id,
              currentTimer.status == .running || currentTimer.status == .paused else {
            cancelAlarm(timerID: previousTimer.id, reportsError: false)
            guard let currentTimer,
                  currentTimer.status == .running,
                  ownsAutomaticCompletion(for: currentTimer.id) else { return }
            enqueueAlarmOperation { [alarmScheduler] in
                try await alarmScheduler.schedule(
                    timerID: currentTimer.id,
                    phase: currentTimer.phase,
                    duration: max(1, currentTimer.remaining(at: date))
                )
            }
            return
        }
        guard currentTimer.status != previousTimer.status
                || currentTimer.phase != previousTimer.phase
                || currentTimer.plannedDurationMs != previousTimer.plannedDurationMs
                || currentTimer.elapsedAtAnchorMs != previousTimer.elapsedAtAnchorMs
                || currentTimer.anchorAt != previousTimer.anchorAt else { return }
        cancelAlarm(timerID: previousTimer.id, reportsError: false)
        guard currentTimer.status == .running else { return }
        enqueueAlarmOperation { [alarmScheduler] in
            try await alarmScheduler.schedule(
                timerID: currentTimer.id,
                phase: currentTimer.phase,
                duration: max(1, currentTimer.remaining(at: date))
            )
        }
    }

    private func enqueueTaskOperation(_ type: TaskOperationType, task: FocusTask) -> Bool {
        let localDate = effectivePhysicalNow() ?? now()
        let occurredAt: Date
        do {
            occurredAt = try trustedOccurrenceDate(localDate: localDate)
        } catch {
            reportInvalidLocalClock()
            return false
        }
        var updated = timerState
        do {
            try updated.advanceClock(at: occurredAt)
            let operationID = try updated.reserveUuidV7()[0]
            updated.mergeKnownTasks([task])
            updated.pendingTaskOperations.append(TaskOperation(
                id: "task-operation-\(operationID.uuidString.lowercased())",
                taskId: task.id.uuidString.lowercased(),
                type: type,
                title: type == .upsert ? task.title : nil,
                occurredAt: occurredAt,
                hlcWallMs: updated.hlcWallMs,
                hlcCounter: updated.hlcCounter
            ))
            if type == .delete, updated.selectedTaskID == task.id {
                try appendSelectedTaskOperation(nil, at: occurredAt, to: &updated)
            }
        } catch {
            reportInvalidLocalClock()
            return false
        }
        timerState = updated
        rebuildOptimisticState()
        guard persist() else { return false }
        Task { await sync() }
        return true
    }

    private func appendSelectedTaskOperation(
        _ selectedTaskID: UUID?,
        at occurredAt: Date,
        to state: inout PersistedTimerState
    ) throws {
        try state.advanceClock(at: occurredAt)
        state.pendingSelectedTaskOperations.append(SelectedTaskOperation(
            id: try state.reserveUuidV7()[0],
            deviceId: state.deviceId,
            taskId: selectedTaskID?.uuidString.lowercased(),
            occurredAt: occurredAt,
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        ))
        state.selectedTaskID = selectedTaskID
    }

    private func cancelAlarm(timerID: String, reportsError: Bool = true) {
        enqueueAlarmOperation(reportsError: reportsError) { [alarmScheduler] in
            try await alarmScheduler.cancel(timerID: timerID)
        }
    }

    private func stopCompletionAlertIfTimerStarted() {
        guard let alertTimerID = completionAlertTimerID,
              let timer = canonicalTimer,
              timer.id != alertTimerID,
              timer.status == .running || timer.status == .paused else { return }
        completionAlertTimerID = nil
        cancelAlarm(timerID: alertTimerID, reportsError: false)
    }

    private func completePermissionIntroduction() {
        defaults.set(true, forKey: Self.permissionIntroductionKey)
        needsPermissionIntroduction = false
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
                    self?.errorMessage = String(localized: "Timer continues in Pomodorough, but its system alarm could not be updated. \(error.localizedDescription)")
                }
            }
        }
    }

    private func rebuildOptimisticState() {
        let result = TimerReducer.applying(
            timerState.localProjection(of: timerState.pendingCommands),
            to: (try? timerState.physicalCanonicalTimer(timerState.canonicalTimer)) ?? timerState.canonicalTimer,
            history: timerState.history
        )
        if replicationMode == .iroh {
            let projected = TimerReducer.projectingTimeCompletion(
                result.timer,
                history: result.history,
                at: effectivePhysicalNow() ?? now()
            )
            canonicalTimer = projected.timer
            history = projected.history
        } else {
            canonicalTimer = result.timer
            history = result.history
        }
        for operation in timerState.pendingTaskOperations where operation.type == .upsert {
            if let title = operation.title, let task = FocusTask(title: title) {
                timerState.mergeKnownTasks([task])
            }
        }
        tasks = TaskReducer.applying(timerState.pendingTaskOperations, to: timerState.tasks)
        timerState.settings.durationsMs = DurationReducer.applying(
            timerState.pendingDurationOperations,
            to: timerState.settings.durationsMs
        )
        if let selected = timerState.selectedTaskID,
           !tasks.contains(where: { $0.id == selected }) {
            timerState.selectedTaskID = nil
        }
        stopCompletionAlertIfTimerStarted()
        if canonicalTimer?.status != .running { completionQueuedFor = nil }
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

    private func completeAuthenticatedSession(user: User, generation: Int) async {
        guard generation == sessionGeneration, isSignedIn else { return }
        guard timerState.hasValidPendingWireOperationsForResample else {
            reportInvalidPendingOperations()
            return
        }
        if let previousUser = timerState.cachedUser, previousUser.id != user.id {
            timerState.pendingAccountSwitchUser = user
            timerState.bootstrapUser = nil
            timerState.pendingBootstrapResolution = nil
            historyResolutionState = .none
            bootstrapSnapshot = nil
            localHistoryResolutionCount = 0
            remoteHistoryResolutionCount = 0
            cancelRevisionStream()
            persist()
            return
        }
        if replicationMode != .centralized {
            if timerState.cachedUser?.id != user.id {
                if timerState.bootstrapUser?.id != user.id {
                    timerState.pendingBootstrapResolution = nil
                }
                timerState.cachedUser = nil
                timerState.bootstrapUser = user
            }
            historyResolutionState = .none
            persist()
            return
        }
        if timerState.cachedUser != nil {
            timerState.prepare(for: user)
            historyResolutionState = .none
            bootstrapSnapshot = nil
            localHistoryResolutionCount = 0
            remoteHistoryResolutionCount = 0
            rebuildOptimisticState()
            persist()
            await sync(force: true)
            return
        }

        if timerState.bootstrapUser?.id != user.id {
            timerState.pendingBootstrapResolution = nil
        }
        timerState.bootstrapUser = user
        persist()
        if let request = timerState.pendingBootstrapResolution {
            await submitPersistedBootstrapResolution(request, generation: generation)
        } else {
            await preflightBootstrapResolution(generation: generation)
        }
    }

    private func preflightBootstrapResolution(generation: Int, autoSubmits: Bool = true) async {
        let modeGeneration = replicationGeneration
        guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration),
              isSignedIn,
              sessionVerification.allows(generation: generation),
              timerState.cachedUser == nil,
              timerState.bootstrapUser?.id == user?.id else { return }
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        historyResolutionState = .preflighting
        isSyncing = false
        do {
            let sampledResponse = try await api.bootstrap(SyncRequest(
                deviceId: timerState.deviceId,
                lastRevision: timerState.revision,
                commands: [],
                taskOperations: [],
                durationOperations: [],
                autoStartOperations: [],
                selectedTaskOperations: []
            ))
            let response = sampledResponse.value
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration),
                  isSignedIn,
                  timerState.cachedUser == nil else { return }
            guard response.hasValidCanonicalSnapshot,
                  WireBounds.containsUnsigned(response.revision) else {
                throw AppError.invalidResponse
            }
            var sampledState = timerState
            try sampledState.mergeClock(
                serverWallMs: response.serverHlcWallMs,
                serverCounter: response.serverHlcCounter,
                serverTime: response.serverTime,
                requestWall: sampledResponse.requestWall,
                requestUptime: sampledResponse.requestUptime,
                responseUptime: sampledResponse.responseUptime
            )
            timerState = sampledState
            persist()
            bootstrapSnapshot = response
            localHistoryResolutionCount = Self.visibleCompletedHistoryCount(history)
            remoteHistoryResolutionCount = Self.visibleCompletedHistoryCount(response.history)
            isOffline = false
            errorMessage = nil

            let localStateExists = hasLocalBootstrapState
            let remoteStateExists = Self.hasRemoteBootstrapState(response)
            if (localHistoryResolutionCount > 0 && remoteStateExists)
                || (remoteHistoryResolutionCount > 0 && localStateExists) {
                historyResolutionState = .choosing
                return
            }

            guard autoSubmits else {
                historyResolutionState = .retryable(nil)
                return
            }

            let strategy: BootstrapResolutionStrategy
            if localHistoryResolutionCount > 0 {
                strategy = .replaceRemote
            } else if remoteHistoryResolutionCount > 0 {
                strategy = .keepRemote
            } else {
                strategy = hasLocalBootstrapState ? .merge : .keepRemote
            }
            await submitBootstrapResolution(strategy: strategy, snapshot: response)
        } catch AppError.unauthorized {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration) else { return }
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.invalidResponse {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = false
            errorMessage = String(localized: "History setup paused because the server returned an invalid response. Local data remains on this device.")
        } catch AppError.historyReplacementUnavailable {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = false
            errorMessage = AppError.historyReplacementUnavailable.localizedDescription
        } catch {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(nil)
            isOffline = true
            scheduleRetry()
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

    private static func hasRemoteBootstrapState(_ response: BootstrapResponse) -> Bool {
        response.canonicalTimer != nil
            || !response.history.isEmpty
            || !response.tasks.isEmpty
            || response.durationsMs != .defaults
            || response.autoStartBreaks
    }

    private static func visibleCompletedHistoryCount(_ history: [HistoryItem]) -> Int {
        history.count { $0.status == CanonicalTimer.Status.completed.rawValue }
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
        let request = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-\(UUID().uuidString.lowercased())",
            deviceId: timerState.deviceId,
            expectedRevision: snapshot.revision,
            strategy: strategy,
            commands: includesLocalOperations ? uploadableCommands() : [],
            taskOperations: includesLocalOperations ? timerState.pendingTaskOperations : [],
            durationOperations: includesLocalOperations ? timerState.pendingDurationOperations : [],
            autoStartOperations: includesLocalOperations
                ? Array(timerState.pendingAutoStartOperations.prefix(4_096))
                : [],
            selectedTaskOperations: includesLocalOperations
                ? Array(timerState.pendingSelectedTaskOperations.prefix(4_096))
                : []
        )
        timerState.pendingBootstrapResolution = request
        persist()
        await submitPersistedBootstrapResolution(request, generation: sessionGeneration)
    }

    private func submitPersistedBootstrapResolution(
        _ request: BootstrapResolveRequest,
        generation: Int
    ) async {
        let modeGeneration = replicationGeneration
        guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration),
              isSignedIn,
              sessionVerification.allows(generation: generation),
              timerState.cachedUser == nil,
              timerState.bootstrapUser?.id == user?.id,
              timerState.pendingBootstrapResolution == request else { return }
        retryTask?.cancel()
        retryTask = nil
        historyResolutionState = .submitting(request.strategy)
        do {
            guard request.deviceId == timerState.deviceId,
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
            let sampledResponse = try await api.resolveBootstrap(request)
            let response = sampledResponse.value
            let receivedAt = effectivePhysicalNow() ?? now()
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration),
                  isSignedIn,
                  timerState.pendingBootstrapResolution == request,
                  let bootstrapUser = timerState.bootstrapUser else { return }
            let previousTimer = activeTimer
            try applyBootstrapResolution(
                response,
                request: request,
                user: bootstrapUser,
                requestWall: sampledResponse.requestWall,
                requestUptime: sampledResponse.requestUptime,
                responseUptime: sampledResponse.responseUptime
            )
            reconcileAlarm(from: previousTimer, to: activeTimer, at: receivedAt)
            await sync(force: true)
        } catch AppError.unauthorized {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration) else { return }
            await invalidateUnauthorizedSession(generation: generation)
        } catch AppError.conflict {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            timerState.pendingBootstrapResolution = nil
            bootstrapSnapshot = nil
            persist()
            await preflightBootstrapResolution(generation: generation, autoSubmits: false)
        } catch AppError.invalidResponse {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = false
            errorMessage = String(localized: "History setup paused because the server returned an invalid response. Your saved choice and local data were preserved.")
        } catch AppError.historyReplacementUnavailable {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = false
            errorMessage = AppError.historyReplacementUnavailable.localizedDescription
        } catch {
            guard ownsCentralizedReplication(generation: generation, modeGeneration: modeGeneration), isSignedIn else { return }
            historyResolutionState = .retryable(request.strategy)
            isOffline = true
            scheduleRetry()
        }
    }

    private func applyBootstrapResolution(
        _ response: BootstrapResponse,
        request: BootstrapResolveRequest,
        user: User,
        requestWall: Date,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval
    ) throws {
        guard response.hasValidCanonicalSnapshot,
              WireBounds.containsUnsigned(response.revision),
              response.revision >= request.expectedRevision else {
            throw AppError.invalidResponse
        }
        let commandAcknowledgements = response.acknowledgements.map(\.commandId)
        let taskAcknowledgements = response.taskAcknowledgements.map(\.operationId)
        let durationAcknowledgements = response.durationAcknowledgements.map(\.operationId)
        let autoStartAcknowledgements = response.autoStartAcknowledgements.map(\.operationId)
        let selectedTaskAcknowledgements = response.selectedTaskAcknowledgements.map(\.operationId)
        let requestedAutoStartOperations = request.autoStartOperations ?? []
        let requestedSelectedTaskOperations = request.selectedTaskOperations ?? []
        guard request.deviceId == timerState.deviceId,
              request.commands.allSatisfy(\.isValid),
              request.taskOperations.allSatisfy(\.isValid),
              request.durationOperations.allSatisfy(\.isValid),
              requestedAutoStartOperations.count <= 4_096,
               requestedAutoStartOperations.allSatisfy({
                 $0.isValid && $0.deviceId == request.deviceId
               }),
               requestedSelectedTaskOperations.count <= 4_096,
               requestedSelectedTaskOperations.allSatisfy({
                 $0.isValid && $0.deviceId == request.deviceId
               }),
              AcknowledgementSet.exactlyMatches(sent: request.commands.map(\.id), acknowledged: commandAcknowledgements),
              AcknowledgementSet.exactlyMatches(sent: request.taskOperations.map(\.id), acknowledged: taskAcknowledgements),
              AcknowledgementSet.exactlyMatches(sent: request.durationOperations.map(\.id), acknowledged: durationAcknowledgements),
               AcknowledgementSet.exactlyMatches(
                 sent: requestedAutoStartOperations.map(\.id),
                 acknowledged: autoStartAcknowledgements
               ),
               AcknowledgementSet.exactlyMatches(
                 sent: requestedSelectedTaskOperations.map(\.id),
                 acknowledged: selectedTaskAcknowledgements
               ) else {
            throw AppError.invalidResponse
        }
        var resolved = timerState
        if request.strategy == .keepRemote {
            resolved.pendingCommands = []
            resolved.localCommandDates = [:]
            resolved.pendingTaskOperations = []
            resolved.pendingDurationOperations = []
            if request.autoStartOperations != nil {
                resolved.pendingAutoStartOperations = []
            }
            if request.selectedTaskOperations != nil {
                resolved.pendingSelectedTaskOperations = []
            }
            resolved.localTimerOwners = [:]
            resolved.provisionalBreaks = []
            resolved.knownTasks = response.tasks
            resolved.legacyTaskAssignments = [:]
        } else {
            let commandIDs = Set(commandAcknowledgements)
            let taskIDs = Set(taskAcknowledgements)
            let durationIDs = Set(durationAcknowledgements)
            let autoStartIDs = Set(autoStartAcknowledgements)
            let selectedTaskIDs = Set(selectedTaskAcknowledgements)
            resolved.pendingCommands.removeAll { commandIDs.contains($0.id) }
            resolved.pendingTaskOperations.removeAll { taskIDs.contains($0.id) }
            resolved.pendingDurationOperations.removeAll { durationIDs.contains($0.id) }
            resolved.pendingAutoStartOperations.removeAll { autoStartIDs.contains($0.id) }
            resolved.pendingSelectedTaskOperations.removeAll { selectedTaskIDs.contains($0.id) }
            resolved.settings.durationsMs = DurationReducer.applying(
                resolved.pendingDurationOperations,
                to: response.durationsMs
            )
            resolveProvisionalBreaks(
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
            resolved.pruneLocalCommandDates()
        }

        resolved.revision = response.revision
        resolved.canonicalTimer = response.canonicalTimer
        resolved.migrateLegacyTimerOwnership()
        resolved.history = response.history
        resolved.tasks = response.tasks
        resolved.autoStartBreaks = response.autoStartBreaks
        try resolved.applySelectedTaskSync(
            canonicalTaskId: response.selectedTaskId,
            canonicalTasks: response.tasks,
            sentOperations: [],
            acknowledgements: []
        )
        resolved.settings.durationsMs = DurationReducer.applying(
            resolved.pendingDurationOperations,
            to: response.durationsMs
        )
        resolved.cachedUser = user
        resolved.bootstrapUser = nil
        resolved.pendingBootstrapResolution = nil
        try resolved.mergeClock(
            serverWallMs: response.serverHlcWallMs,
            serverCounter: response.serverHlcCounter,
            serverTime: response.serverTime,
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
        try resolved.rebasePendingOperations(
            afterServerWallMs: response.serverHlcWallMs,
            serverCounter: response.serverHlcCounter,
            serverTime: response.serverTime
        )
        timerState = resolved
        bootstrapSnapshot = nil
        historyResolutionState = .none
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        isOffline = false
        errorMessage = nil
        rebuildOptimisticState()
        pruneLocalTimerOwners()
        persist()
    }

    private func verifyRestoredSession(generation: Int) async {
        guard generation == sessionGeneration,
              isSignedIn,
              !sessionVerification.allows(generation: generation),
              timerState.cachedUser != nil || timerState.bootstrapUser != nil,
              sessionVerificationOwner == nil else { return }
        let owner = UUID()
        sessionVerificationOwner = owner
        defer {
            if sessionVerificationOwner == owner { sessionVerificationOwner = nil }
        }
        do {
            let response = try await api.me()
            guard generation == sessionGeneration,
                  isSignedIn,
                  sessionVerificationOwner == owner else { return }
            sessionVerification.markVerified(generation: generation)
            sessionState = .signedIn(response.user)
            isOffline = false
            await completeAuthenticatedSession(user: response.user, generation: generation)
        } catch AppError.unauthorized {
            await invalidateUnauthorizedSession(generation: generation)
        } catch {
            guard generation == sessionGeneration,
                  isSignedIn,
                  sessionVerificationOwner == owner else { return }
            isOffline = true
            scheduleRetry()
        }
    }

    private func invalidateUnauthorizedSession(generation: Int) async {
        guard generation == sessionGeneration else { return }
        sessionGeneration += 1
        sessionVerification.invalidate()
        sessionVerificationOwner = nil
        syncOwnership.invalidate()
        isWorking = false
        isSyncing = false
        revisionHints = RevisionHintCoalescer()
        retryTask?.cancel()
        retryTask = nil
        cancelRevisionStream()
        sessionState = .localOnly
        let preservesBootstrapResolution = timerState.cachedUser == nil && timerState.bootstrapUser != nil
        historyResolutionState = preservesBootstrapResolution
            ? .retryable(timerState.pendingBootstrapResolution?.strategy)
            : .none
        bootstrapSnapshot = nil
        localHistoryResolutionCount = 0
        remoteHistoryResolutionCount = 0
        isOffline = false
        errorMessage = AppError.unauthorized.localizedDescription
        try? await api.clearTokens()
    }

    private func scheduleRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        let retryDelay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            if self.isHistoryResolutionBlocking {
                await self.retryHistoryResolution()
            } else {
                await self.sync(force: true)
            }
        }
    }

    private func startRemotePolling() {
        guard replicationMode == .centralized,
              isSignedIn,
              !isWorkspaceMutationBlocked,
              sessionVerification.allows(generation: sessionGeneration),
              revisionLifecycle.isActive,
              remotePollingTask == nil else { return }
        let generation = sessionGeneration
        remotePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.isActive else { return }
                let interval = RemotePolling.interval(isTimerActive: self.isTimerActive)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.isActive else { return }
                await self.sync(force: true, showsActivity: false)
            }
        }
    }

    private func startRevisionStream() {
        guard replicationMode == .centralized,
              isSignedIn,
              !isWorkspaceMutationBlocked,
              sessionVerification.allows(generation: sessionGeneration),
              let streamID = revisionLifecycle.begin() else { return }
        let generation = sessionGeneration
        revisionStreamTask = Task { [weak self] in
            var retryDelay = 1.0
            while !Task.isCancelled {
                guard let self,
                      generation == self.sessionGeneration,
                      self.isSignedIn,
                      self.revisionLifecycle.owns(streamID) else { return }
                do {
                    let events = try await self.api.revisionEvents()
                    for try await revision in events {
                        guard !Task.isCancelled,
                              generation == self.sessionGeneration,
                              self.isSignedIn,
                              self.revisionLifecycle.owns(streamID) else { return }
                        retryDelay = 1
                        await self.receiveRevisionHint(revision)
                    }
                } catch is CancellationError {
                    return
                } catch AppError.unauthorized {
                    guard !Task.isCancelled,
                          generation == self.sessionGeneration,
                          self.isSignedIn,
                          self.revisionLifecycle.owns(streamID) else { return }
                    await self.invalidateUnauthorizedSession(generation: generation)
                    return
                } catch {
                    guard !Task.isCancelled, self.revisionLifecycle.owns(streamID) else { return }
                    // The stream is advisory. Its initial event catches up missed revisions after reconnecting.
                }

                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    private func receiveRevisionHint(_ revision: Int64) async {
        if revisionHints.receive(revision, localRevision: timerState.revision, isSyncing: isSyncing) {
            await sync(force: true)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        if replicationMode == .iroh {
            let durableState = roomStore.activeRoomState
            do {
                timerState = try roomStore.captureLocalOperations(from: timerState)
                Task { [irohService] in await irohService.syncNow() }
            } catch {
                if let durableState {
                    timerState = durableState
                    rebuildOptimisticState()
                }
                conflictMessage = error.localizedDescription
                if case IrohProtocolError.immutableConflict = error {
                    irohStatus = .conflict
                    let roomID = roomStore.activeRoomID
                    Task { [irohService] in await irohService.markConflict(roomID: roomID) }
                }
                return false
            }
            return true
        }
        if let data = try? JSONEncoder.api.encode(timerState) {
            defaults.set(data, forKey: Self.storageKey)
            return true
        }
        return false
    }

    private func startIrohIfNeeded() async {
        guard replicationMode == .iroh,
              let room = activeRoom,
              room.conflict == nil,
              let secret = roomStore.activeRoomSecret else { return }
#if os(iOS)
        guard sceneIsActive else { return }
#endif
        do {
            _ = try await irohService.start(irohContext(roomID: room.roomID, secret: secret))
        } catch {
            irohStatus = .unavailable(error.localizedDescription)
        }
    }

    private func scheduleIrohStartup() {
        irohStartupTask?.cancel()
        guard replicationMode == .iroh,
              let room = activeRoom,
              room.conflict == nil,
              let secret = roomStore.activeRoomSecret else { return }
#if os(iOS)
        guard sceneIsActive else { return }
#endif
        let service = irohService
        let context = irohContext(roomID: room.roomID, secret: secret)
        irohStartupTask = Task { [weak self, service] in
            do {
                _ = try await service.start(context)
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard self?.replicationMode == .iroh,
                          self?.activeRoom?.roomID == context.roomID else { return }
                    self?.irohStatus = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func applyIrohProjection(_ state: PersistedTimerState, roomID: String) {
        guard replicationMode == .iroh,
              roomStore.activeRoomID == roomID,
              let state = roomStore.activeRoomState else { return }
        let previous = activeTimer
        var updated = state
        if Self.advanceDefaultPhaseAfterIrohCompletion(in: &updated) {
            do {
                updated = try roomStore.captureLocalOperations(from: updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        timerState = updated
        rebuildOptimisticState()
        reconcileAlarm(from: previous, to: activeTimer, at: effectivePhysicalNow() ?? now())
    }

    private static func advanceDefaultPhaseAfterIrohCompletion(
        in state: inout PersistedTimerState
    ) -> Bool {
        guard !state.hasExplicitPhaseSelection,
              let timer = state.canonicalTimer,
              timer.status == .completed else { return false }
        let nextPhase: TimerPhase
        if timer.phase == .focus {
            let completionDate = state.history.first {
                $0.timerId == timer.id && $0.status == CanonicalTimer.Status.completed.rawValue
            }.flatMap { $0.completedAt ?? $0.endedAt } ?? timer.anchorAt
            nextPhase = TimerReducer.breakPhase(
                afterCompletedFocusCount: completedFocusCount(
                    in: state.history,
                    on: completionDate
                )
            )
        } else {
            nextPhase = .focus
        }
        guard state.settings.selectedPhase != nextPhase else { return false }
        state.settings.selectedPhase = nextPhase
        return true
    }

    private func irohContext(roomID: String, secret: Data) -> IrohServiceContext {
        IrohServiceContext(
            roomID: roomID,
            roomSecret: secret,
            deviceID: timerState.deviceId,
            displayName: nil,
            platform: Self.platform
        )
    }

    private func secureRandomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private func reportInvalidLocalClock() {
        conflictMessage = String(localized: "Saved sequence or trusted-time state is invalid. No local change was saved.")
        errorMessage = AppError.invalidLocalClock.localizedDescription
    }

    private func reportInvalidPendingOperations() {
        conflictMessage = String(localized: "Queued changes contain invalid sequence or trusted-time values.")
        errorMessage = String(localized: "Sync paused because queued changes failed local validation. No queued changes were sent or modified.")
        isOffline = false
        cancelRevisionStream()
    }

    private static let storageKey = "timer-state-v2"
    private static let localTaskStorageKey = "local-tasks-v1"
    private static let permissionIntroductionKey = "permission-introduction-completed-v1"
    private static let replicationModeKey = "replication-mode-v1"

    private static func hasPersistedDurationOperations(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains("pendingDurationOperations")
    }

    private static func hasPersistedAutoStartOperations(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains("pendingAutoStartOperations")
    }

    private static func hasPersistedSelectedTaskOperations(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains("pendingSelectedTaskOperations")
    }

    private static func hasExplicitLegacyAutoStartBreaks(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any] else { return false }
        return settings["autoStartBreaksExplicitlySet"] as? Bool == true
    }

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
        model.sessionState = scenario == .resolving || scenario == .signedIn
            ? .signedIn(User(id: "preview-user", email: "alex@example.com", name: "Alex", avatarUrl: ""))
            : .localOnly
        model.needsPermissionIntroduction = false
        model.historyResolutionState = scenario == .resolving ? .choosing : .none
        model.localHistoryResolutionCount = scenario == .resolving ? 2 : 0
        model.remoteHistoryResolutionCount = scenario == .resolving ? 4 : 0
        model.rebuildOptimisticState()
        return model
    }
}
#endif
