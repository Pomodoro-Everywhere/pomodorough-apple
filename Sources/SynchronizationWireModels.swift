import Foundation

struct SyncRequest: Encodable, Sendable {
    let deviceId: String
    let lastRevision: Int64
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
    let selectedTaskOperations: [SelectedTaskOperation]

    init(
        deviceId: String,
        lastRevision: Int64,
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation]?,
        selectedTaskOperations: [SelectedTaskOperation] = []
    ) {
        self.deviceId = deviceId
        self.lastRevision = lastRevision
        self.commands = commands
        self.taskOperations = taskOperations
        self.durationOperations = durationOperations
        self.autoStartOperations = autoStartOperations
        self.selectedTaskOperations = selectedTaskOperations
    }
}

enum BootstrapResolutionStrategy: String, Codable, Equatable, Sendable {
    case keepRemote = "keep_remote"
    case replaceRemote = "replace_remote"
    case merge

    var title: String {
        switch self {
        case .keepRemote: String(localized: "Keep Remote")
        case .replaceRemote: String(localized: "Keep Local")
        case .merge: String(localized: "Keep Both")
        }
    }
}

struct BootstrapResolveRequest: Codable, Equatable, Sendable {
    let requestId: String
    let deviceId: String
    let expectedRevision: Int64
    let strategy: BootstrapResolutionStrategy
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
    let selectedTaskOperations: [SelectedTaskOperation]?

    init(
        requestId: String,
        deviceId: String,
        expectedRevision: Int64,
        strategy: BootstrapResolutionStrategy,
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation]?,
        selectedTaskOperations: [SelectedTaskOperation]? = nil
    ) {
        self.requestId = requestId
        self.deviceId = deviceId
        self.expectedRevision = expectedRevision
        self.strategy = strategy
        self.commands = commands
        self.taskOperations = taskOperations
        self.durationOperations = durationOperations
        self.autoStartOperations = autoStartOperations
        self.selectedTaskOperations = selectedTaskOperations
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, deviceId, expectedRevision, strategy, commands, taskOperations
        case durationOperations, autoStartOperations, selectedTaskOperations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try values.decode(String.self, forKey: .requestId)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        expectedRevision = try values.decode(Int64.self, forKey: .expectedRevision)
        strategy = try values.decode(BootstrapResolutionStrategy.self, forKey: .strategy)
        commands = try values.decode([TimerCommand].self, forKey: .commands)
        taskOperations = try values.decode([TaskOperation].self, forKey: .taskOperations)
        durationOperations = try values.decode([DurationOperation].self, forKey: .durationOperations)
        autoStartOperations = try values.decodeIfPresent(
            [AutoStartOperation].self,
            forKey: .autoStartOperations
        )
        selectedTaskOperations = try values.decodeIfPresent(
            [SelectedTaskOperation].self,
            forKey: .selectedTaskOperations
        )
    }
}

struct SyncResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let selectedTaskAcknowledgements: [SelectedTaskAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case selectedTaskAcknowledgements, durationsMs, autoStartBreaks, selectedTaskId
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decodeIfPresent([TaskAcknowledgement].self, forKey: .taskAcknowledgements) ?? []
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        selectedTaskAcknowledgements = try values.decode(
            [SelectedTaskAcknowledgement].self,
            forKey: .selectedTaskAcknowledgements
        )
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        guard values.contains(.selectedTaskId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.selectedTaskId,
                .init(codingPath: values.codingPath, debugDescription: "Sync response requires selectedTaskId.")
            )
        }
        selectedTaskId = try values.decodeIfPresent(String.self, forKey: .selectedTaskId)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }

    var hasValidCanonicalSnapshot: Bool {
        CanonicalSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs,
            selectedTaskId: selectedTaskId
        )
    }
}

struct BootstrapResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let selectedTaskAcknowledgements: [SelectedTaskAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case selectedTaskAcknowledgements, durationsMs, autoStartBreaks, selectedTaskId
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.canonicalTimer), values.contains(.selectedTaskId) else {
            throw DecodingError.keyNotFound(
                values.contains(.canonicalTimer) ? CodingKeys.selectedTaskId : CodingKeys.canonicalTimer,
                DecodingError.Context(
                    codingPath: values.codingPath,
                    debugDescription: "Bootstrap response must include canonicalTimer and selectedTaskId."
                )
            )
        }
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decode([TaskAcknowledgement].self, forKey: .taskAcknowledgements)
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        selectedTaskAcknowledgements = try values.decode(
            [SelectedTaskAcknowledgement].self,
            forKey: .selectedTaskAcknowledgements
        )
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        selectedTaskId = try values.decodeIfPresent(String.self, forKey: .selectedTaskId)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }

    var hasValidCanonicalSnapshot: Bool {
        CanonicalSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs,
            selectedTaskId: selectedTaskId
        )
    }
}

enum CanonicalSnapshotValidation {
    static func isValid(
        timer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durations: DurationValues,
        selectedTaskId: String?
    ) -> Bool {
        durations.isValid
            && (timer?.isValid ?? true)
            && history.allSatisfy(\.isValid)
            && tasks.allSatisfy(\.isValid)
            && Set(history.map(\.id)).count == history.count
            && Set(history.map(\.timerId)).count == history.count
            && Set(tasks.map(\.id)).count == tasks.count
            && (selectedTaskId == nil || selectedTaskId.flatMap(UUID.init(uuidString:)).map { selected in
                tasks.contains { $0.id == selected }
            } == true)
    }
}

struct HistoryResponse: Decodable, Sendable { let history: [HistoryItem] }
