import Foundation

struct PersistedTimerState: Codable, Equatable, Sendable {
    var deviceId: String
    var nextSequence: Int64
    var sequenceExhausted: Bool
    var revision: Int64
    var hlcWallMs: Int64
    var hlcCounter: Int64
    var serverTimeOffsetMs: Int64?
    var serverTimeUncertaintyMs: Int64?
    var serverTimeAnchorMs: Int64?
    var serverTimeAnchorUptime: TimeInterval?
    var lastTrustedTimeMs: Int64?
    var lastUuidV7: UUID?
    var pendingCommands: [TimerCommand]
    var localCommandDates: [String: Date]
    var pendingTaskOperations: [TaskOperation]
    var pendingDurationOperations: [DurationOperation]
    var pendingAutoStartOperations: [AutoStartOperation]
    var pendingSelectedTaskOperations: [SelectedTaskOperation]
    var autoStartBreaks: Bool
    var localTimerOwners: [String: String]
    var provisionalBreaks: [ProvisionalBreak]
    var provisionalPhaseAdvances: [ProvisionalPhaseAdvance]
    var selectedPhaseGeneration: Int64
    var hasExplicitPhaseSelection: Bool
    var canonicalTimer: CanonicalTimer?
    var history: [HistoryItem]
    var tasks: [FocusTask]
    var knownTasks: [FocusTask]
    var selectedTaskID: UUID?
    var legacyTaskAssignments: [String: UUID]
    var hasCorruptPendingOperations: Bool
    var settings: TimerSettings
    var cachedUser: User?
    var pendingAccountSwitchUser: User?
    var bootstrapUser: User?
    var pendingBootstrapResolution: BootstrapResolveRequest?

    var trustedClockState: TrustedClockState {
        get {
            TrustedClockState(
                offsetMs: serverTimeOffsetMs,
                uncertaintyMs: serverTimeUncertaintyMs,
                anchorMs: serverTimeAnchorMs,
                anchorUptime: serverTimeAnchorUptime,
                lastEmittedMs: lastTrustedTimeMs
            )
        }
        set {
            serverTimeOffsetMs = newValue.offsetMs
            serverTimeUncertaintyMs = newValue.uncertaintyMs
            serverTimeAnchorMs = newValue.anchorMs
            serverTimeAnchorUptime = newValue.anchorUptime
            lastTrustedTimeMs = newValue.lastEmittedMs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, nextSequence, sequenceExhausted, revision, hlcWallMs, hlcCounter
        case serverTimeOffsetMs, serverTimeUncertaintyMs, serverTimeAnchorMs
        case serverTimeAnchorUptime, lastTrustedTimeMs, lastUuidV7, localCommandDates
        case pendingCommands, pendingTaskOperations, pendingDurationOperations, pendingAutoStartOperations
        case pendingSelectedTaskOperations
        case autoStartBreaks, localTimerOwners, provisionalBreaks, provisionalPhaseAdvances
        case selectedPhaseGeneration, hasExplicitPhaseSelection, canonicalTimer, history
        case tasks, knownTasks, selectedTaskID, legacyTaskAssignments, hasCorruptPendingOperations
        case settings, cachedUser, pendingAccountSwitchUser
        case bootstrapUser, pendingBootstrapResolution
    }

    // size-exception: compatibility initializer is atomic inventory of every durable field.
    init(
        deviceId: String,
        nextSequence: Int64,
        sequenceExhausted: Bool = false,
        revision: Int64,
        hlcWallMs: Int64,
        hlcCounter: Int64,
        serverTimeOffsetMs: Int64? = nil,
        serverTimeUncertaintyMs: Int64? = nil,
        serverTimeAnchorMs: Int64? = nil,
        serverTimeAnchorUptime: TimeInterval? = nil,
        lastTrustedTimeMs: Int64? = nil,
        lastUuidV7: UUID? = nil,
        pendingCommands: [TimerCommand],
        localCommandDates: [String: Date] = [:],
        pendingTaskOperations: [TaskOperation],
        pendingDurationOperations: [DurationOperation],
        pendingAutoStartOperations: [AutoStartOperation],
        pendingSelectedTaskOperations: [SelectedTaskOperation] = [],
        autoStartBreaks: Bool,
        localTimerOwners: [String: String],
        provisionalBreaks: [ProvisionalBreak],
        provisionalPhaseAdvances: [ProvisionalPhaseAdvance] = [],
        selectedPhaseGeneration: Int64 = 0,
        hasExplicitPhaseSelection: Bool = false,
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        knownTasks: [FocusTask],
        selectedTaskID: UUID?,
        legacyTaskAssignments: [String: UUID],
        hasCorruptPendingOperations: Bool = false,
        settings: TimerSettings,
        cachedUser: User?,
        pendingAccountSwitchUser: User? = nil,
        bootstrapUser: User?,
        pendingBootstrapResolution: BootstrapResolveRequest?
    ) {
        self.deviceId = deviceId
        self.nextSequence = nextSequence
        self.sequenceExhausted = sequenceExhausted
        self.revision = revision
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
        self.serverTimeOffsetMs = serverTimeOffsetMs
        self.serverTimeUncertaintyMs = serverTimeUncertaintyMs
        self.serverTimeAnchorMs = serverTimeAnchorMs
        self.serverTimeAnchorUptime = serverTimeAnchorUptime
        self.lastTrustedTimeMs = lastTrustedTimeMs
        self.lastUuidV7 = lastUuidV7
        self.pendingCommands = pendingCommands
        self.localCommandDates = localCommandDates
        self.pendingTaskOperations = pendingTaskOperations
        self.pendingDurationOperations = pendingDurationOperations
        self.pendingAutoStartOperations = pendingAutoStartOperations
        self.pendingSelectedTaskOperations = pendingSelectedTaskOperations
        self.autoStartBreaks = autoStartBreaks
        self.localTimerOwners = localTimerOwners
        self.provisionalBreaks = provisionalBreaks
        self.provisionalPhaseAdvances = provisionalPhaseAdvances
        self.selectedPhaseGeneration = selectedPhaseGeneration
        self.hasExplicitPhaseSelection = hasExplicitPhaseSelection
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.tasks = tasks
        self.knownTasks = knownTasks
        self.selectedTaskID = selectedTaskID
        self.legacyTaskAssignments = legacyTaskAssignments
        self.hasCorruptPendingOperations = hasCorruptPendingOperations
        self.settings = settings
        self.cachedUser = cachedUser
        self.pendingAccountSwitchUser = pendingAccountSwitchUser
        self.bootstrapUser = bootstrapUser
        self.pendingBootstrapResolution = pendingBootstrapResolution
    }

    init(from decoder: Decoder) throws {
        self = try PersistedStateSchema.decode(from: decoder)
    }
}

extension PersistedTimerState {
    static func fresh() -> Self {
        Self(
            deviceId: "device-\(UUID().uuidString.lowercased())",
            nextSequence: 1,
            sequenceExhausted: false,
            revision: 0,
            hlcWallMs: 0,
            hlcCounter: 0,
            serverTimeOffsetMs: nil,
            serverTimeUncertaintyMs: nil,
            serverTimeAnchorMs: nil,
            serverTimeAnchorUptime: nil,
            lastTrustedTimeMs: nil,
            lastUuidV7: nil,
            pendingCommands: [],
            localCommandDates: [:],
            pendingTaskOperations: [],
            pendingDurationOperations: [],
            pendingAutoStartOperations: [],
            pendingSelectedTaskOperations: [],
            autoStartBreaks: false,
            localTimerOwners: [:],
            provisionalBreaks: [],
            provisionalPhaseAdvances: [],
            selectedPhaseGeneration: 0,
            hasExplicitPhaseSelection: false,
            canonicalTimer: nil,
            history: [],
            tasks: [],
            knownTasks: [],
            selectedTaskID: nil,
            legacyTaskAssignments: [:],
            hasCorruptPendingOperations: false,
            settings: TimerSettings(),
            cachedUser: nil,
            pendingAccountSwitchUser: nil,
            bootstrapUser: nil,
            pendingBootstrapResolution: nil
        )
    }
}

enum PersistedStateSchema {
    static func decode(from decoder: Decoder) throws -> PersistedTimerState {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let generator = try decodeGenerator(from: values)
        let pending = try decodePending(from: values)
        let room = try decodeRoom(from: values)
        let account = try decodeAccount(from: values)
        return PersistedTimerState(
            deviceId: generator.deviceId,
            nextSequence: generator.nextSequence,
            sequenceExhausted: generator.sequenceExhausted,
            revision: generator.revision,
            hlcWallMs: generator.hlcWallMs,
            hlcCounter: generator.hlcCounter,
            serverTimeOffsetMs: generator.serverTimeOffsetMs,
            serverTimeUncertaintyMs: generator.serverTimeUncertaintyMs,
            serverTimeAnchorMs: generator.serverTimeAnchorMs,
            serverTimeAnchorUptime: generator.serverTimeAnchorUptime,
            lastTrustedTimeMs: generator.lastTrustedTimeMs,
            lastUuidV7: generator.lastUuidV7,
            pendingCommands: pending.commands,
            localCommandDates: pending.localCommandDates,
            pendingTaskOperations: pending.taskOperations,
            pendingDurationOperations: pending.durationOperations,
            pendingAutoStartOperations: pending.autoStartOperations,
            pendingSelectedTaskOperations: pending.selectedTaskOperations,
            autoStartBreaks: room.autoStartBreaks,
            localTimerOwners: room.localTimerOwners,
            provisionalBreaks: room.provisionalBreaks,
            provisionalPhaseAdvances: room.provisionalPhaseAdvances,
            selectedPhaseGeneration: room.selectedPhaseGeneration,
            hasExplicitPhaseSelection: room.hasExplicitPhaseSelection,
            canonicalTimer: room.canonicalTimer,
            history: room.history,
            tasks: room.tasks,
            knownTasks: room.knownTasks,
            selectedTaskID: room.selectedTaskID,
            legacyTaskAssignments: room.legacyTaskAssignments,
            hasCorruptPendingOperations: pending.hasCorruptOperations,
            settings: room.settings,
            cachedUser: account.cachedUser,
            pendingAccountSwitchUser: account.pendingAccountSwitchUser,
            bootstrapUser: account.bootstrapUser,
            pendingBootstrapResolution: account.pendingBootstrapResolution
        )
    }

    private struct LossyDecodable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) {
            value = try? Value(from: decoder)
        }
    }

    private struct DecodedGeneratorState {
        let deviceId: String
        let nextSequence: Int64
        let sequenceExhausted: Bool
        let revision: Int64
        let hlcWallMs: Int64
        let hlcCounter: Int64
        let serverTimeOffsetMs: Int64?
        let serverTimeUncertaintyMs: Int64?
        let serverTimeAnchorMs: Int64?
        let serverTimeAnchorUptime: TimeInterval?
        let lastTrustedTimeMs: Int64?
        let lastUuidV7: UUID?
    }

    private struct DecodedPendingState {
        let commands: [TimerCommand]
        let localCommandDates: [String: Date]
        let taskOperations: [TaskOperation]
        let durationOperations: [DurationOperation]
        let autoStartOperations: [AutoStartOperation]
        let selectedTaskOperations: [SelectedTaskOperation]
        let hasCorruptOperations: Bool
    }

    private struct DecodedRoomState {
        let autoStartBreaks: Bool
        let localTimerOwners: [String: String]
        let provisionalBreaks: [ProvisionalBreak]
        let provisionalPhaseAdvances: [ProvisionalPhaseAdvance]
        let selectedPhaseGeneration: Int64
        let hasExplicitPhaseSelection: Bool
        let canonicalTimer: CanonicalTimer?
        let history: [HistoryItem]
        let tasks: [FocusTask]
        let knownTasks: [FocusTask]
        let selectedTaskID: UUID?
        let legacyTaskAssignments: [String: UUID]
        let settings: TimerSettings
    }

    private struct DecodedAccountState {
        let cachedUser: User?
        let pendingAccountSwitchUser: User?
        let bootstrapUser: User?
        let pendingBootstrapResolution: BootstrapResolveRequest?
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, nextSequence, sequenceExhausted, revision, hlcWallMs, hlcCounter
        case serverTimeOffsetMs, serverTimeUncertaintyMs, serverTimeAnchorMs
        case serverTimeAnchorUptime, lastTrustedTimeMs, lastUuidV7, localCommandDates
        case pendingCommands, pendingTaskOperations, pendingDurationOperations, pendingAutoStartOperations
        case pendingSelectedTaskOperations
        case autoStartBreaks, localTimerOwners, provisionalBreaks, provisionalPhaseAdvances
        case selectedPhaseGeneration, hasExplicitPhaseSelection, canonicalTimer, history
        case tasks, knownTasks, selectedTaskID, legacyTaskAssignments, hasCorruptPendingOperations
        case settings, cachedUser, pendingAccountSwitchUser
        case bootstrapUser, pendingBootstrapResolution
    }

    private static func decodeGenerator(
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> DecodedGeneratorState {
        try DecodedGeneratorState(
            deviceId: values.decode(String.self, forKey: .deviceId),
            nextSequence: values.decode(Int64.self, forKey: .nextSequence),
            sequenceExhausted: values.decodeIfPresent(Bool.self, forKey: .sequenceExhausted) ?? false,
            revision: values.decode(Int64.self, forKey: .revision),
            hlcWallMs: values.decodeIfPresent(Int64.self, forKey: .hlcWallMs) ?? 0,
            hlcCounter: values.decodeIfPresent(Int64.self, forKey: .hlcCounter) ?? 0,
            serverTimeOffsetMs: values.decodeIfPresent(Int64.self, forKey: .serverTimeOffsetMs),
            serverTimeUncertaintyMs: values.decodeIfPresent(Int64.self, forKey: .serverTimeUncertaintyMs),
            serverTimeAnchorMs: values.decodeIfPresent(Int64.self, forKey: .serverTimeAnchorMs),
            serverTimeAnchorUptime: values.decodeIfPresent(TimeInterval.self, forKey: .serverTimeAnchorUptime),
            lastTrustedTimeMs: values.decodeIfPresent(Int64.self, forKey: .lastTrustedTimeMs),
            lastUuidV7: values.decodeIfPresent(UUID.self, forKey: .lastUuidV7)
        )
    }

    private static func decodePending(
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> DecodedPendingState {
        let autoStart = try values.decodeIfPresent(
            [LossyDecodable<AutoStartOperation>].self,
            forKey: .pendingAutoStartOperations
        ) ?? []
        let selectedTask = try values.decodeIfPresent(
            [LossyDecodable<SelectedTaskOperation>].self,
            forKey: .pendingSelectedTaskOperations
        ) ?? []
        let persistedCorruption = try values.decodeIfPresent(
            Bool.self,
            forKey: .hasCorruptPendingOperations
        ) ?? false
        return try DecodedPendingState(
            commands: values.decode([TimerCommand].self, forKey: .pendingCommands),
            localCommandDates: values.decodeIfPresent([String: Date].self, forKey: .localCommandDates) ?? [:],
            taskOperations: values.decodeIfPresent([TaskOperation].self, forKey: .pendingTaskOperations) ?? [],
            durationOperations: values.decodeIfPresent([DurationOperation].self, forKey: .pendingDurationOperations)?
                .map(normalizedLegacySentinel) ?? [],
            autoStartOperations: autoStart.compactMap(\.value).map(normalizedLegacySentinel),
            selectedTaskOperations: selectedTask.compactMap(\.value).map(normalizedLegacySentinel),
            hasCorruptOperations: persistedCorruption
                || autoStart.contains { $0.value == nil }
                || selectedTask.contains { $0.value == nil }
        )
    }

    private static func decodeRoom(
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> DecodedRoomState {
        let tasks = try values.decodeIfPresent([FocusTask].self, forKey: .tasks) ?? []
        return try DecodedRoomState(
            autoStartBreaks: values.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? false,
            localTimerOwners: values.decodeIfPresent([String: String].self, forKey: .localTimerOwners) ?? [:],
            provisionalBreaks: values.decodeIfPresent([ProvisionalBreak].self, forKey: .provisionalBreaks) ?? [],
            provisionalPhaseAdvances: values.decodeIfPresent(
                [ProvisionalPhaseAdvance].self,
                forKey: .provisionalPhaseAdvances
            ) ?? [],
            selectedPhaseGeneration: values.decodeIfPresent(Int64.self, forKey: .selectedPhaseGeneration) ?? 0,
            hasExplicitPhaseSelection: values.decodeIfPresent(Bool.self, forKey: .hasExplicitPhaseSelection) ?? false,
            canonicalTimer: values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer),
            history: values.decode([HistoryItem].self, forKey: .history),
            tasks: tasks,
            knownTasks: values.decodeIfPresent([FocusTask].self, forKey: .knownTasks) ?? tasks,
            selectedTaskID: values.decodeIfPresent(UUID.self, forKey: .selectedTaskID),
            legacyTaskAssignments: values.decodeIfPresent([String: UUID].self, forKey: .legacyTaskAssignments) ?? [:],
            settings: values.decodeIfPresent(TimerSettings.self, forKey: .settings) ?? TimerSettings()
        )
    }

    private static func decodeAccount(
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> DecodedAccountState {
        try DecodedAccountState(
            cachedUser: values.decodeIfPresent(User.self, forKey: .cachedUser),
            pendingAccountSwitchUser: values.decodeIfPresent(User.self, forKey: .pendingAccountSwitchUser),
            bootstrapUser: values.decodeIfPresent(User.self, forKey: .bootstrapUser),
            pendingBootstrapResolution: values.decodeIfPresent(
                BootstrapResolveRequest.self,
                forKey: .pendingBootstrapResolution
            ).map(normalizedLegacySentinels)
        )
    }

    private static func normalizedLegacySentinel(_ operation: DurationOperation) -> DurationOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return DurationOperation(
            id: operation.id,
            phase: operation.phase,
            durationMs: operation.durationMs,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinel(_ operation: AutoStartOperation) -> AutoStartOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return AutoStartOperation(
            id: operation.id,
            deviceId: operation.deviceId,
            enabled: operation.enabled,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinel(_ operation: SelectedTaskOperation) -> SelectedTaskOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return SelectedTaskOperation(
            id: operation.id,
            deviceId: operation.deviceId,
            taskId: operation.taskId,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinels(
        _ request: BootstrapResolveRequest
    ) -> BootstrapResolveRequest {
        BootstrapResolveRequest(
            requestId: request.requestId,
            deviceId: request.deviceId,
            expectedRevision: request.expectedRevision,
            strategy: request.strategy,
            commands: request.commands,
            taskOperations: request.taskOperations,
            durationOperations: request.durationOperations.map(normalizedLegacySentinel),
            autoStartOperations: request.autoStartOperations?.map(normalizedLegacySentinel),
            selectedTaskOperations: request.selectedTaskOperations?.map(normalizedLegacySentinel)
        )
    }
}
