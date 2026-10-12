import Foundation

struct WorkspaceIntentWorkspace: Encodable, Sendable {
    let base: WorkspaceIntentBase
    let local: WorkspaceIntentLocal
    let canonicalHead: WorkspaceIntentHead?
    let neverSent: WorkspaceIntentNeverSent
    let timerDependencies: [CoreTimerDependency]

    private enum CodingKeys: String, CodingKey {
        case base
        case local
        case canonicalHead
        case neverSent
        case timerDependencies
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base, forKey: .base)
        try container.encode(local, forKey: .local)
        if let canonicalHead {
            try container.encode(canonicalHead, forKey: .canonicalHead)
        } else {
            try container.encodeNil(forKey: .canonicalHead)
        }
        try container.encode(neverSent, forKey: .neverSent)
        try container.encode(timerDependencies, forKey: .timerDependencies)
    }
}

struct WorkspaceIntentBase: Encodable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?

    private enum CodingKeys: String, CodingKey {
        case canonicalTimer
        case history
        case tasks
        case durationsMs
        case autoStartBreaks
        case selectedTaskId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let canonicalTimer {
            try container.encode(canonicalTimer, forKey: .canonicalTimer)
        } else {
            try container.encodeNil(forKey: .canonicalTimer)
        }
        try container.encode(history, forKey: .history)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(durationsMs, forKey: .durationsMs)
        try container.encode(autoStartBreaks, forKey: .autoStartBreaks)
        if let selectedTaskId {
            try container.encode(selectedTaskId, forKey: .selectedTaskId)
        } else {
            try container.encodeNil(forKey: .selectedTaskId)
        }
    }
}

struct WorkspaceIntentLocal: Encodable, Sendable {
    let commands: [CoreTimerCommand]
    let taskOperations: [CoreTaskOperation]
    let durationOperations: [CoreDurationOperation]
    let autoStartOperations: [CoreAutoStartOperation]
    let selectedTaskOperations: [CoreSelectedTaskOperation]
}

struct WorkspaceIntentNeverSent: Encodable, Sendable {
    let commands: [String]
    let taskOperations: [String]
    let durationOperations: [String]
    let autoStartOperations: [String]
    let selectedTaskOperations: [String]
}

enum WorkspaceIntentKind: Encodable, Sendable {
    case start
    case pause
    case resume
    case cancel
    case cancelAndClear
    case clear
    case selectPhase(TimerPhase)
    case upsertTask(String)
    case deleteTask(String)
    case selectTask(String?)
    case setDuration(TimerPhase, Int)
    case setAutoStart(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case phase
        case title
        case taskId
        case minutes
        case enabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start:
            try container.encode("start", forKey: .kind)
        case .pause:
            try container.encode("pause", forKey: .kind)
        case .resume:
            try container.encode("resume", forKey: .kind)
        case .cancel:
            try container.encode("cancel", forKey: .kind)
        case .cancelAndClear:
            try container.encode("cancelAndClear", forKey: .kind)
        case .clear:
            try container.encode("clear", forKey: .kind)
        case .selectPhase(let phase):
            try container.encode("selectPhase", forKey: .kind)
            try container.encode(phase, forKey: .phase)
        case .upsertTask(let title):
            try container.encode("upsertTask", forKey: .kind)
            try container.encode(title, forKey: .title)
        case .deleteTask(let taskId):
            try container.encode("deleteTask", forKey: .kind)
            try container.encode(taskId, forKey: .taskId)
        case .selectTask(let taskId):
            try container.encode("selectTask", forKey: .kind)
            if let taskId {
                try container.encode(taskId, forKey: .taskId)
            } else {
                try container.encodeNil(forKey: .taskId)
            }
        case .setDuration(let phase, let minutes):
            try container.encode("setDuration", forKey: .kind)
            try container.encode(phase, forKey: .phase)
            try container.encode(minutes, forKey: .minutes)
        case .setAutoStart(let enabled):
            try container.encode("setAutoStart", forKey: .kind)
            try container.encode(enabled, forKey: .enabled)
        }
    }
}

struct WorkspaceIntentRequest: Encodable, Sendable {
    let compatibility = "appleWorkspace"
    let replicationMode: String
    let intent: WorkspaceIntentKind
    let workspace: WorkspaceIntentWorkspace
    let selection: WorkspaceIntentSelection
    let allocation: WorkspaceIntentAllocation
    let observation: WorkspaceIntentObservation
    let clock: WorkspaceIntentClock
    let identities: WorkspaceIntentIdentities
    let calendarIntervals: [WorkspaceIntentInterval]
    let ownership: WorkspaceIntentOwnership?
    let durability: WorkspaceIntentDurability?
    let localDurationsMs: DurationValues?

    private enum CodingKeys: String, CodingKey {
        case compatibility
        case replicationMode
        case intent
        case workspace
        case selection
        case allocation
        case observation
        case clock
        case identities
        case calendarIntervals
        case ownership
        case durability
        case localDurationsMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encode(replicationMode, forKey: .replicationMode)
        try container.encode(intent, forKey: .intent)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(selection, forKey: .selection)
        try container.encode(allocation, forKey: .allocation)
        try container.encode(observation, forKey: .observation)
        try container.encode(clock, forKey: .clock)
        try container.encode(identities, forKey: .identities)
        try container.encode(calendarIntervals, forKey: .calendarIntervals)
        if let ownership {
            try container.encode(ownership, forKey: .ownership)
        }
        if let durability {
            try container.encode(durability, forKey: .durability)
        }
        if let localDurationsMs {
            try container.encode(localDurationsMs, forKey: .localDurationsMs)
        }
    }
}

struct WorkspaceIntentOutcome: Decodable, Sendable {
    let id: String
    let outcome: String
}

struct WorkspaceIntentGroupOutcomes: Decodable, Sendable {
    let commands: [WorkspaceIntentOutcome]?
    let taskOperations: [WorkspaceIntentOutcome]?
    let durationOperations: [WorkspaceIntentOutcome]?
    let autoStartOperations: [WorkspaceIntentOutcome]?
    let selectedTaskOperations: [WorkspaceIntentOutcome]?
}

struct WorkspaceIntentResponseWorkspace: Decodable, Sendable {
    let base: WorkspaceIntentResponseBase?
    let local: WorkspaceIntentResponseLocal?
    let canonicalHead: WorkspaceIntentHead?
    let neverSent: WorkspaceIntentResponseNeverSent?
    let timerDependencies: [CoreTimerDependency]?
}

struct WorkspaceIntentResponseBase: Decodable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]?
    let tasks: [FocusTask]?
    let durationsMs: DurationValues?
    let autoStartBreaks: Bool?
    let selectedTaskId: String?
}

struct WorkspaceIntentResponseLocal: Decodable, Sendable {
    let commands: [CoreTimerCommand]?
    let taskOperations: [CoreTaskOperation]?
    let durationOperations: [CoreDurationOperation]?
    let autoStartOperations: [CoreAutoStartOperation]?
    let selectedTaskOperations: [CoreSelectedTaskOperation]?
}

struct WorkspaceIntentResponseNeverSent: Decodable, Sendable {
    let commands: [String]?
    let taskOperations: [String]?
    let durationOperations: [String]?
    let autoStartOperations: [String]?
    let selectedTaskOperations: [String]?
}

struct WorkspaceIntentResponseAllocation: Decodable, Sendable {
    let deviceId: String?
    let deviceSequence: Int64?
    let hlc: WorkspaceIntentHLC?
    let lastUuid: String?
}

struct WorkspaceIntentResponseObservation: Decodable, Sendable {
    let canonicalAnchorAt: String?
    let commandTimes: [String: Date]?
}

struct WorkspaceIntentResponseSelection: Decodable, Sendable {
    let phase: TimerPhase?
    let generation: String?
    let explicit: Bool?
}

struct WorkspaceIntentEffect: Decodable, Sendable {
    let kind: String
    let timerId: String?
    let phase: TimerPhase?
    let durationMs: Int64?
}

struct WorkspaceIntentResponse: Decodable, Sendable {
    let schemaVersion: Int?
    let outcome: String?
    let reason: String?
    let workspace: WorkspaceIntentResponseWorkspace?
    let selection: WorkspaceIntentResponseSelection?
    let allocation: WorkspaceIntentResponseAllocation?
    let observation: WorkspaceIntentResponseObservation?
    let commands: [CoreTimerCommand]?
    let atomicCommandIds: [String]?
    let operations: WorkspaceIntentResponseLocal?
    let atomicOperationIds: WorkspaceIntentResponseLocalIds?
    let retiredDurationOperationIds: [String]?
    let groupOutcomes: WorkspaceIntentGroupOutcomes?
    let commandOutcomes: [WorkspaceIntentOutcome]?
    let ownershipWrites: [WorkspaceIntentOwnershipWrite]?
    let projection: CoreProjectionOutput?
    let effectsAfterCommit: [WorkspaceIntentEffect]?
}

struct WorkspaceIntentResponseLocalIds: Decodable, Sendable {
    let commands: [String]?
    let taskOperations: [String]?
    let durationOperations: [String]?
    let autoStartOperations: [String]?
    let selectedTaskOperations: [String]?
}

struct WorkspaceIntentOwnershipWrite: Decodable, Sendable {
    let kind: String
    let timerId: String?
    let deviceId: String?
    let startCommandId: String?
}
