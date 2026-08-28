import Foundation

enum SharedCoreError: Error, Equatable, LocalizedError, Sendable {
    case resourceMissing
    case runtimeInitializationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case missingExport(String)
    case invalidExportSignature(String)
    case inputTooLarge(Int)
    case allocationFailed(length: Int)
    case memoryOutOfBounds(pointer: UInt32, length: UInt32, byteCount: Int)
    case invalidABIResult(String)
    case invalidInput(String)
    case core(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            String(localized: "Bundled pomodorough_core.wasm resource is missing.")
        case .runtimeInitializationFailed(let message):
            String(localized: "Shared core WebAssembly initialization failed: \(message)")
        case .checksumMismatch(let expected, let actual):
            String(localized: "Shared core SHA-256 mismatch: expected \(expected), got \(actual).")
        case .missingExport(let name):
            String(localized: "Shared core WebAssembly export is missing: \(name).")
        case .invalidExportSignature(let name):
            String(localized: "Shared core WebAssembly export has an invalid signature: \(name).")
        case .inputTooLarge(let length):
            String(localized: "Shared core input exceeds the 32-bit ABI length: \(length) bytes.")
        case .allocationFailed(let length):
            String(localized: "Shared core failed to allocate \(length) bytes.")
        case .memoryOutOfBounds(let pointer, let length, let byteCount):
            String(localized: "Shared core memory range \(pointer)..<\(UInt64(pointer) + UInt64(length)) exceeds \(byteCount) bytes.")
        case .invalidABIResult(let message):
            String(localized: "Shared core returned an invalid ABI result: \(message)")
        case .invalidInput(let message):
            String(localized: "Shared core input is invalid: \(message)")
        case .core(let message):
            String(localized: "Shared core rejected the operation: \(message)")
        case .invalidResponse(let message):
            String(localized: "Shared core returned an invalid response: \(message)")
        }
    }
}

struct CoreHLC: Codable, Equatable, Sendable {
    let wallMs: Int64
    let counter: Int64
}

struct CoreHLCHeadInput: Encodable, Equatable, Sendable {
    let physicalNowMs: Int64
    let observed: [CoreHLC]
}

extension CoreHLC {
    func validatedHead(for input: CoreHLCHeadInput) throws -> Self {
        guard WireBounds.containsUnsigned(wallMs),
              WireBounds.containsUnsigned(counter),
              wallMs >= input.physicalNowMs else {
            throw SharedCoreError.invalidResponse("hlc.head.v1 output is invalid")
        }
        return self
    }
}

struct CoreHLCTickInput: Encodable, Equatable, Sendable {
    let local: CoreHLC
    let remote: CoreHLC?
    let physicalNowMs: Int64
}

struct CoreHLCTickOutput: Decodable, Equatable, Sendable {
    let wallMs: Int64
    let counter: Int64

    func validated(for input: CoreHLCTickInput) throws -> Self {
        let output = (wallMs, counter)
        let local = (input.local.wallMs, input.local.counter)
        let followsRemote = input.remote.map {
            output > ($0.wallMs, $0.counter)
        } ?? true
        guard WireBounds.containsUnsigned(wallMs),
              WireBounds.containsUnsigned(counter),
              wallMs >= input.physicalNowMs,
              output > local,
              followsRemote else {
            throw SharedCoreError.invalidResponse("hlc.tick.v1 output is invalid or non-monotonic")
        }
        return self
    }
}

struct CoreCompletionOwnership: Encodable, Equatable, Sendable {
    let timerId: String
    let ownerDeviceId: String
}

struct CoreCompletionSource: Encodable, Equatable, Sendable {
    let commandId: String
    let timerId: String
    let phase: TimerPhase
    let occurredAt: Date
}

struct CoreCompletionIdentity: Encodable, Equatable, Sendable {
    let commandId: String
    let timerId: String
}

struct CoreCompletionProjection: Encodable, Equatable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
}

struct CoreCompletionExpiryInput: Encodable, Sendable {
    let kind = "expiry"
    let beforeTimer: CanonicalTimer?
    let projectedTimer: CanonicalTimer?
    let history: [HistoryItem]
    let selectedPhase: TimerPhase
    let autoStartBreaks: Bool
    let localDeviceId: String
    let ownership: CoreCompletionOwnership?
    let dayStart: Date
    let dayEnd: Date
}

struct CoreCompletionCommandRequestInput: Encodable, Sendable {
    let kind = "commandRequest"
    let commandType: CommandType
    let requestedTimer: CanonicalTimer?
    let projectedTimer: CanonicalTimer?
    let automatic: Bool
    let generateAutoBreak: Bool
    let autoStartBreaks: Bool
    let localDeviceId: String
    let ownership: CoreCompletionOwnership?
}

struct CoreCompletionFinishAppliedInput: Encodable, Sendable {
    let kind = "finishApplied"
    let source: CoreCompletionSource
    let history: [HistoryItem]
    let autoStartBreaks: Bool
    let localDeviceId: String
    let ownership: CoreCompletionOwnership?
    let dayStart: Date
    let dayEnd: Date
}

struct CoreCompletionGeneratedBreakInput: Encodable, Sendable {
    let kind = "generatedBreak"
    let source: CoreCompletionIdentity
    let canonical: CoreCompletionProjection
    let optimistic: CoreCompletionProjection
    let sourceFinishPending: Bool
    let requireCanonical: Bool
    let dayStart: Date
    let dayEnd: Date
}

enum CoreCompletionPlanInput: Encodable, Sendable {
    case expiry(CoreCompletionExpiryInput)
    case commandRequest(CoreCompletionCommandRequestInput)
    case finishApplied(CoreCompletionFinishAppliedInput)
    case generatedBreak(CoreCompletionGeneratedBreakInput)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .expiry(let input): try input.encode(to: encoder)
        case .commandRequest(let input): try input.encode(to: encoder)
        case .finishApplied(let input): try input.encode(to: encoder)
        case .generatedBreak(let input): try input.encode(to: encoder)
        }
    }
}

struct CoreCompletionPlanOutput: Decodable, Equatable, Sendable {
    let expired: Bool
    let commandEligible: Bool
    let reserveGeneratedBreak: Bool
    let selectedPhase: TimerPhase?
    let queueAutoBreak: Bool
    let generatedBreakEligible: Bool
    let generatedBreakPhase: TimerPhase?
    let sourceAlreadyAccepted: Bool
}

extension CoreCompletionPlanOutput {
    func validated(for input: CoreCompletionPlanInput) throws -> Self {
        let valid: Bool
        switch input {
        case .expiry: valid = validExpiry
        case .commandRequest: valid = validCommandRequest
        case .finishApplied: valid = validFinishApplied
        case .generatedBreak(let generated): valid = validGeneratedBreak(for: generated)
        }
        guard valid else {
            throw SharedCoreError.invalidResponse(
                "timer.completionPlan.v1 output is internally inconsistent"
            )
        }
        return self
    }

    private var validExpiry: Bool {
        !commandEligible && !reserveGeneratedBreak && !queueAutoBreak
            && !generatedBreakEligible && !sourceAlreadyAccepted
            && (expired || (selectedPhase == nil && generatedBreakPhase == nil))
    }

    private var validCommandRequest: Bool {
        !expired && selectedPhase == nil && !queueAutoBreak
            && !generatedBreakEligible && generatedBreakPhase == nil
            && !sourceAlreadyAccepted && (!reserveGeneratedBreak || commandEligible)
    }

    private var validFinishApplied: Bool {
        !expired && !commandEligible && !reserveGeneratedBreak
            && selectedPhase != nil && !generatedBreakEligible
            && generatedBreakPhase == nil && !sourceAlreadyAccepted
    }

    private func validGeneratedBreak(for input: CoreCompletionGeneratedBreakInput) -> Bool {
        let canonicalHasSource = input.canonical.hasExactSource(input.source)
        let sourceAccepted = !input.sourceFinishPending && canonicalHasSource
        let selected = input.requireCanonical || sourceAccepted
            ? input.canonical
            : input.optimistic
        return !expired && !commandEligible && !reserveGeneratedBreak
            && selectedPhase == nil && !queueAutoBreak
            && generatedBreakEligible == (generatedBreakPhase != nil)
            && generatedBreakEligible == selected.hasExactSource(input.source)
            && sourceAlreadyAccepted == sourceAccepted
    }
}

private extension CoreCompletionProjection {
    func hasExactSource(_ source: CoreCompletionIdentity) -> Bool {
        canonicalTimer?.id == source.timerId
            && canonicalTimer?.phase == .focus
            && canonicalTimer?.status == .completed
            && history.contains {
                $0.timerId == source.timerId
                    && $0.commandId == source.commandId
                    && $0.phase == .focus
                    && $0.status == "completed"
            }
    }
}

struct CoreProjectionBase: Encodable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?

    init(
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durationsMs: DurationValues,
        autoStartBreaks: Bool,
        selectedTaskId: String?
    ) {
        // Core rejects duplicated terminal state. Older Apple snapshots kept both.
        self.canonicalTimer = history.contains(where: { $0.timerId == canonicalTimer?.id })
            ? nil
            : canonicalTimer
        self.history = history
        self.tasks = tasks
        self.durationsMs = durationsMs
        self.autoStartBreaks = autoStartBreaks
        self.selectedTaskId = selectedTaskId
    }
}

struct CoreTimerCommand: Codable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let deviceSequence: Int64
    let timerId: String
    let taskId: String?
    let type: CommandType
    let phase: TimerPhase
    let plannedDurationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let observedElapsedMs: Int64

    init(_ command: TimerCommand, deviceId: String) {
        id = command.id
        self.deviceId = deviceId
        deviceSequence = command.deviceSequence
        timerId = command.timerId
        taskId = command.taskId
        type = command.type
        phase = command.phase
        plannedDurationMs = command.plannedDurationMs
        occurredAt = command.occurredAt
        hlcWallMs = command.hlcWallMs
        hlcCounter = command.hlcCounter
        observedElapsedMs = command.observedElapsedMs
    }

    func native(deviceId expectedDeviceId: String) throws -> TimerCommand {
        let command = TimerCommand(
            id: id,
            deviceSequence: deviceSequence,
            timerId: timerId,
            taskId: taskId,
            type: type,
            phase: phase,
            plannedDurationMs: plannedDurationMs,
            occurredAt: occurredAt,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter,
            observedElapsedMs: observedElapsedMs
        )
        guard deviceId == expectedDeviceId, command.isValid else {
            throw SharedCoreError.invalidResponse("invalid rebased timer command")
        }
        return command
    }
}

struct CoreTaskOperation: Codable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let taskId: String
    let type: TaskOperationType
    let title: String
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: TaskOperation, deviceId: String) {
        id = operation.id
        self.deviceId = deviceId
        taskId = operation.taskId
        type = operation.type
        title = operation.title ?? ""
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    func native(deviceId expectedDeviceId: String) throws -> TaskOperation {
        let operation = TaskOperation(
            id: id,
            taskId: taskId,
            type: type,
            title: type == .delete ? nil : title,
            occurredAt: occurredAt,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        )
        guard deviceId == expectedDeviceId, operation.isValid else {
            throw SharedCoreError.invalidResponse("invalid rebased task operation")
        }
        return operation
    }
}

struct CoreDurationOperation: Codable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let phase: TimerPhase
    let durationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: DurationOperation, deviceId: String) {
        id = operation.id
        self.deviceId = deviceId
        phase = operation.phase
        durationMs = operation.durationMs
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    func native(deviceId expectedDeviceId: String) throws -> DurationOperation {
        let operation = DurationOperation(
            id: id,
            phase: phase,
            durationMs: durationMs,
            occurredAt: occurredAt,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        )
        guard deviceId == expectedDeviceId, operation.isValid else {
            throw SharedCoreError.invalidResponse("invalid rebased duration operation")
        }
        return operation
    }
}

struct CoreAutoStartOperation: Codable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: AutoStartOperation) {
        id = operation.id.uuidString.lowercased()
        deviceId = operation.deviceId
        enabled = operation.enabled
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    init(_ operation: IrohAutoStartOperation, deviceId: String) {
        id = operation.id
        self.deviceId = deviceId
        enabled = operation.enabled
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    func native(deviceId expectedDeviceId: String) throws -> AutoStartOperation {
        guard let identifier = UUID(uuidString: id) else {
            throw SharedCoreError.invalidResponse("invalid rebased auto-start operation id")
        }
        let operation = AutoStartOperation(
            id: identifier,
            deviceId: deviceId,
            enabled: enabled,
            occurredAt: occurredAt,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        )
        guard deviceId == expectedDeviceId, operation.isValid else {
            throw SharedCoreError.invalidResponse("invalid rebased auto-start operation")
        }
        return operation
    }
}

struct CoreSelectedTaskOperation: Codable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let taskId: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: SelectedTaskOperation) {
        id = operation.id.uuidString.lowercased()
        deviceId = operation.deviceId
        taskId = operation.taskId
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    init(_ operation: IrohSelectedTaskOperation, deviceId: String) {
        id = operation.id
        self.deviceId = deviceId
        taskId = operation.taskId
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    private enum CodingKeys: String, CodingKey {
        case id, deviceId, taskId, occurredAt, hlcWallMs, hlcCounter
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(deviceId, forKey: .deviceId)
        if let taskId {
            try values.encode(taskId, forKey: .taskId)
        } else {
            try values.encodeNil(forKey: .taskId)
        }
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
    }

    func native(deviceId expectedDeviceId: String) throws -> SelectedTaskOperation {
        guard let identifier = UUID(uuidString: id) else {
            throw SharedCoreError.invalidResponse("invalid rebased selected-task operation id")
        }
        let operation = SelectedTaskOperation(
            id: identifier,
            deviceId: deviceId,
            taskId: taskId,
            occurredAt: occurredAt,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        )
        guard deviceId == expectedDeviceId, operation.isValid else {
            throw SharedCoreError.invalidResponse("invalid rebased selected-task operation")
        }
        return operation
    }
}

struct CoreProjectionPending: Encodable, Sendable {
    let commands: [CoreTimerCommand]
    let taskOperations: [CoreTaskOperation]
    let durationOperations: [CoreDurationOperation]
    let autoStartOperations: [CoreAutoStartOperation]
    let selectedTaskOperations: [CoreSelectedTaskOperation]
}

struct CoreProjectionInput: Encodable, Sendable {
    let base: CoreProjectionBase
    let pending: CoreProjectionPending
    let now: Date
}

struct CoreProjectionTimerOutcome: Decodable, Equatable, Sendable {
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct CoreProjectionWinningOperationIDs: Decodable, Equatable, Sendable {
    let tasks: [String: String]
    let durations: [String: String]
    let autoStart: String?
    let selectedTask: String?
}

struct CoreProjectionOutput: Decodable, Equatable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let timerOutcomes: [String: CoreProjectionTimerOutcome]
    let winningOperationIds: CoreProjectionWinningOperationIDs

    func validated(for input: CoreProjectionInput) throws -> Self {
        guard hasValidSnapshot,
              hasUniquePendingIdentifiers(input.pending),
              hasCompleteTimerOutcomes(input.pending.commands),
              hasConsistentTaskWinners(input.pending.taskOperations),
              hasConsistentDurationWinners(input.pending.durationOperations),
              hasConsistentAutoStartWinner(input.pending.autoStartOperations),
              hasConsistentSelectedTaskWinner(input.pending.selectedTaskOperations) else {
            throw SharedCoreError.invalidResponse("projection.apply.v2 output failed structural or winner validation")
        }
        return self
    }

    private var hasValidSnapshot: Bool {
        IrohSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs
        ) && selectedTaskId.map { selected in
            tasks.contains { $0.id.uuidString.lowercased() == selected.lowercased() }
        } ?? true
    }

    private func hasUniquePendingIdentifiers(_ pending: CoreProjectionPending) -> Bool {
        let identifiers = pending.commands.map(\.id)
            + pending.taskOperations.map(\.id)
            + pending.durationOperations.map(\.id)
            + pending.autoStartOperations.map(\.id)
            + pending.selectedTaskOperations.map(\.id)
        return identifiers.allSatisfy { !$0.isEmpty }
            && Set(identifiers).count == identifiers.count
    }

    private func hasCompleteTimerOutcomes(_ commands: [CoreTimerCommand]) -> Bool {
        timerOutcomes.count == commands.count
            && Set(timerOutcomes.keys) == Set(commands.map(\.id))
    }

    private func hasConsistentTaskWinners(_ operations: [CoreTaskOperation]) -> Bool {
        guard let winners = Self.referencedWinners(
            winningOperationIds.tasks,
            operations: operations,
            target: \.taskId,
            identifier: \.id
        ) else { return false }
        let projected = Dictionary(uniqueKeysWithValues: tasks.map {
            ($0.id.uuidString.lowercased(), $0)
        })
        return winners.allSatisfy { target, operation in
            switch operation.type {
            case .upsert:
                projected[target.lowercased()]?.title == operation.title
            case .delete:
                projected[target.lowercased()] == nil
            }
        }
    }

    private func hasConsistentDurationWinners(_ operations: [CoreDurationOperation]) -> Bool {
        guard let winners = Self.referencedWinners(
            winningOperationIds.durations,
            operations: operations,
            target: { $0.phase.rawValue },
            identifier: \.id
        ) else { return false }
        return winners.allSatisfy { target, operation in
            target == operation.phase.rawValue
                && durationsMs.durationMs(for: operation.phase) == operation.durationMs
        }
    }

    private func hasConsistentAutoStartWinner(_ operations: [CoreAutoStartOperation]) -> Bool {
        guard operations.isEmpty == (winningOperationIds.autoStart == nil) else { return false }
        guard let identifier = winningOperationIds.autoStart else { return true }
        guard let winner = operations.first(where: { $0.id == identifier }) else { return false }
        return autoStartBreaks == winner.enabled
    }

    private func hasConsistentSelectedTaskWinner(
        _ operations: [CoreSelectedTaskOperation]
    ) -> Bool {
        guard operations.isEmpty == (winningOperationIds.selectedTask == nil) else { return false }
        guard let identifier = winningOperationIds.selectedTask else { return true }
        guard let winner = operations.first(where: { $0.id == identifier }) else { return false }
        let selected = winner.taskId.flatMap { candidate in
            tasks.first { $0.id.uuidString.lowercased() == candidate.lowercased() }
        }?.id.uuidString.lowercased()
        return selectedTaskId?.lowercased() == selected
    }

    private static func referencedWinners<Operation>(
        _ references: [String: String],
        operations: [Operation],
        target: (Operation) -> String,
        identifier: KeyPath<Operation, String>
    ) -> [String: Operation]? {
        let groups = Dictionary(grouping: operations, by: target)
        guard Set(references.keys) == Set(groups.keys),
              Set(references.values).count == references.count else { return nil }
        var winners: [String: Operation] = [:]
        for (target, identifierValue) in references {
            guard let operation = groups[target]?.first(where: {
                $0[keyPath: identifier] == identifierValue
            }) else { return nil }
            winners[target] = operation
        }
        return winners
    }
}

struct CoreBootstrapPlanInput: Encodable, Equatable, Sendable {
    let localOwnerId: String?
    let currentUserId: String?
    let localHistory: [HistoryItem]
    let remoteHistory: [HistoryItem]
    let hasLocalState: Bool
    let hasRemoteState: Bool
}

enum CoreBootstrapPlanMode: String, Decodable, Equatable, Sendable {
    case choose
    case auto
    case normalSync = "normal_sync"
}

struct CoreBootstrapPlanOutput: Decodable, Equatable, Sendable {
    let mode: CoreBootstrapPlanMode
    let strategy: BootstrapResolutionStrategy?
    let reason: String?
    let localHistoryCount: Int?
    let remoteHistoryCount: Int?

    func validated() throws -> Self {
        let valid: Bool
        switch mode {
        case .choose:
            valid = strategy == nil
                && reason == nil
                && localHistoryCount != nil
                && remoteHistoryCount != nil
        case .auto:
            valid = strategy != nil
                && reason != nil
                && localHistoryCount == nil
                && remoteHistoryCount == nil
        case .normalSync:
            valid = strategy == nil
                && reason == "same_owner"
                && localHistoryCount == nil
                && remoteHistoryCount == nil
        }
        guard valid else {
            throw SharedCoreError.invalidResponse("bootstrap.plan.v1 output failed structural validation")
        }
        return self
    }
}

struct CoreReconcileLocalQueues: Encodable, Equatable, Sendable {
    let commands: [CoreTimerCommand]
    let taskOperations: [CoreTaskOperation]
    let durationOperations: [CoreDurationOperation]
    let autoStartOperations: [CoreAutoStartOperation]
    let selectedTaskOperations: [CoreSelectedTaskOperation]

    init(state: PersistedTimerState) {
        commands = state.pendingCommands.map { CoreTimerCommand($0, deviceId: state.deviceId) }
        taskOperations = state.pendingTaskOperations.map { CoreTaskOperation($0, deviceId: state.deviceId) }
        durationOperations = state.pendingDurationOperations.map {
            CoreDurationOperation($0, deviceId: state.deviceId)
        }
        autoStartOperations = state.pendingAutoStartOperations.map(CoreAutoStartOperation.init)
        selectedTaskOperations = state.pendingSelectedTaskOperations.map(CoreSelectedTaskOperation.init)
    }
}

struct CoreReconcileSentQueues: Encodable, Equatable, Sendable {
    private struct Identifier: Encodable, Equatable, Sendable {
        let id: String
    }

    private let commands: [Identifier]
    private let taskOperations: [Identifier]
    private let durationOperations: [Identifier]
    private let autoStartOperations: [Identifier]
    private let selectedTaskOperations: [Identifier]

    init(
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation],
        selectedTaskOperations: [SelectedTaskOperation]
    ) {
        self.commands = commands.map { Identifier(id: $0.id) }
        self.taskOperations = taskOperations.map { Identifier(id: $0.id) }
        self.durationOperations = durationOperations.map { Identifier(id: $0.id) }
        self.autoStartOperations = autoStartOperations.map { Identifier(id: $0.id.uuidString.lowercased()) }
        self.selectedTaskOperations = selectedTaskOperations.map {
            Identifier(id: $0.id.uuidString.lowercased())
        }
    }
}

struct CoreTimerDependency: Codable, Equatable, Sendable {
    let operationId: String
    let dependsOnOperationId: String
    let generatedBreak: Bool
    let sourceDayStart: Date?
    let sourceDayEnd: Date?

    init(
        operationId: String,
        dependsOnOperationId: String,
        generatedBreak: Bool = false,
        sourceDayStart: Date? = nil,
        sourceDayEnd: Date? = nil
    ) {
        self.operationId = operationId
        self.dependsOnOperationId = dependsOnOperationId
        self.generatedBreak = generatedBreak
        self.sourceDayStart = sourceDayStart
        self.sourceDayEnd = sourceDayEnd
    }
}

struct CoreReconcileCanonicalResponse: Encodable, Equatable, Sendable {
    struct TimerAcknowledgement: Encodable, Equatable, Sendable {
        let commandId: String
        let outcome: AcknowledgementOutcome
        let reason: String

        init(_ value: Acknowledgement) {
            commandId = value.commandId
            outcome = value.outcome
            reason = value.reason
        }
    }

    struct OperationAcknowledgement: Encodable, Equatable, Sendable {
        let operationId: String
        let outcome: AcknowledgementOutcome
        let reason: String
    }

    let acknowledgements: [TimerAcknowledgement]
    let taskAcknowledgements: [OperationAcknowledgement]
    let durationAcknowledgements: [OperationAcknowledgement]
    let autoStartAcknowledgements: [OperationAcknowledgement]
    let selectedTaskAcknowledgements: [OperationAcknowledgement]
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private init(
        acknowledgements: [Acknowledgement],
        taskAcknowledgements: [TaskAcknowledgement],
        durationAcknowledgements: [DurationAcknowledgement],
        autoStartAcknowledgements: [AutoStartAcknowledgement],
        selectedTaskAcknowledgements: [SelectedTaskAcknowledgement],
        revision: Int64,
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durationsMs: DurationValues,
        autoStartBreaks: Bool,
        selectedTaskId: String?,
        serverTime: Date,
        serverHlcWallMs: Int64,
        serverHlcCounter: Int64
    ) {
        self.acknowledgements = acknowledgements.map(TimerAcknowledgement.init)
        self.taskAcknowledgements = taskAcknowledgements.map {
            OperationAcknowledgement(operationId: $0.operationId, outcome: $0.outcome, reason: $0.reason)
        }
        self.durationAcknowledgements = durationAcknowledgements.map {
            OperationAcknowledgement(operationId: $0.operationId, outcome: $0.outcome, reason: $0.reason)
        }
        self.autoStartAcknowledgements = autoStartAcknowledgements.map {
            OperationAcknowledgement(operationId: $0.operationId.uuidString.lowercased(), outcome: $0.outcome, reason: $0.reason)
        }
        self.selectedTaskAcknowledgements = selectedTaskAcknowledgements.map {
            OperationAcknowledgement(operationId: $0.operationId.uuidString.lowercased(), outcome: $0.outcome, reason: $0.reason)
        }
        self.revision = revision
        self.canonicalTimer = history.contains(where: { $0.timerId == canonicalTimer?.id })
            ? nil
            : canonicalTimer
        self.history = history
        self.tasks = tasks
        self.durationsMs = durationsMs
        self.autoStartBreaks = autoStartBreaks
        self.selectedTaskId = selectedTaskId
        self.serverTime = serverTime
        self.serverHlcWallMs = serverHlcWallMs
        self.serverHlcCounter = serverHlcCounter
    }

    init(_ response: SyncResponse) {
        self.init(
            acknowledgements: response.acknowledgements,
            taskAcknowledgements: response.taskAcknowledgements,
            durationAcknowledgements: response.durationAcknowledgements,
            autoStartAcknowledgements: response.autoStartAcknowledgements,
            selectedTaskAcknowledgements: response.selectedTaskAcknowledgements,
            revision: response.revision,
            canonicalTimer: response.canonicalTimer,
            history: response.history,
            tasks: response.tasks,
            durationsMs: response.durationsMs,
            autoStartBreaks: response.autoStartBreaks,
            selectedTaskId: response.selectedTaskId,
            serverTime: response.serverTime,
            serverHlcWallMs: response.serverHlcWallMs,
            serverHlcCounter: response.serverHlcCounter
        )
    }

    init(_ response: BootstrapResponse) {
        self.init(
            acknowledgements: response.acknowledgements,
            taskAcknowledgements: response.taskAcknowledgements,
            durationAcknowledgements: response.durationAcknowledgements,
            autoStartAcknowledgements: response.autoStartAcknowledgements,
            selectedTaskAcknowledgements: response.selectedTaskAcknowledgements,
            revision: response.revision,
            canonicalTimer: response.canonicalTimer,
            history: response.history,
            tasks: response.tasks,
            durationsMs: response.durationsMs,
            autoStartBreaks: response.autoStartBreaks,
            selectedTaskId: response.selectedTaskId,
            serverTime: response.serverTime,
            serverHlcWallMs: response.serverHlcWallMs,
            serverHlcCounter: response.serverHlcCounter
        )
    }

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements
        case autoStartAcknowledgements, selectedTaskAcknowledgements, revision
        case canonicalTimer, history, tasks, durationsMs, autoStartBreaks
        case selectedTaskId, serverTime, serverHlcWallMs, serverHlcCounter
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(acknowledgements, forKey: .acknowledgements)
        try values.encode(taskAcknowledgements, forKey: .taskAcknowledgements)
        try values.encode(durationAcknowledgements, forKey: .durationAcknowledgements)
        try values.encode(autoStartAcknowledgements, forKey: .autoStartAcknowledgements)
        try values.encode(selectedTaskAcknowledgements, forKey: .selectedTaskAcknowledgements)
        try values.encode(revision, forKey: .revision)
        if let canonicalTimer {
            try values.encode(canonicalTimer, forKey: .canonicalTimer)
        } else {
            try values.encodeNil(forKey: .canonicalTimer)
        }
        try values.encode(history, forKey: .history)
        try values.encode(tasks, forKey: .tasks)
        try values.encode(durationsMs, forKey: .durationsMs)
        try values.encode(autoStartBreaks, forKey: .autoStartBreaks)
        if let selectedTaskId {
            try values.encode(selectedTaskId, forKey: .selectedTaskId)
        } else {
            try values.encodeNil(forKey: .selectedTaskId)
        }
        try values.encode(serverTime, forKey: .serverTime)
        try values.encode(serverHlcWallMs, forKey: .serverHlcWallMs)
        try values.encode(serverHlcCounter, forKey: .serverHlcCounter)
    }
}

struct CoreReconcileInput: Encodable, Equatable, Sendable {
    let local: CoreReconcileLocalQueues
    let sent: CoreReconcileSentQueues
    let response: CoreReconcileCanonicalResponse
    let timerDependencies: [CoreTimerDependency]
}

struct CoreReconcileOutput: Decodable, Equatable, Sendable {
    let revision: Int64
    let pending: [CoreTimerCommand]
    let pendingTaskOperations: [CoreTaskOperation]
    let pendingDurationOperations: [CoreDurationOperation]
    let pendingAutoStartOperations: [CoreAutoStartOperation]
    let pendingSelectedTaskOperations: [CoreSelectedTaskOperation]
    let pendingTimerDependencies: [CoreTimerDependency]
    let promotedTimerOperationIds: [String]
    let droppedTimerOperationIds: [String]
    let droppedTimerIds: [String]
    let baseTimer: CanonicalTimer?
    let baseHistory: [HistoryItem]
    let baseTasks: [FocusTask]
    let baseDurationsMs: DurationValues
    let baseAutoStartBreaks: Bool
    let baseSelectedTaskId: String?
    let timer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?

    private static func wireDatesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            guard WireBounds.physicalMilliseconds(for: lhs) != nil,
                  WireBounds.physicalMilliseconds(for: rhs) != nil else {
                return false
            }
            return abs(lhs.timeIntervalSince(rhs)) <= 0.001_1
        default:
            return false
        }
    }

    private static func wireHistoriesEqual(
        _ lhs: [HistoryItem],
        _ rhs: [HistoryItem]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { lhs, rhs in
            lhs.id == rhs.id
                && lhs.timerId == rhs.timerId
                && lhs.commandId == rhs.commandId
                && lhs.taskId == rhs.taskId
                && lhs.phase == rhs.phase
                && lhs.status == rhs.status
                && lhs.plannedDurationMs == rhs.plannedDurationMs
                && wireDatesEqual(lhs.completedAt, rhs.completedAt)
                && wireDatesEqual(lhs.endedAt, rhs.endedAt)
        }
    }

    private static func wireTimersEqual(
        _ lhs: CanonicalTimer?,
        _ rhs: CanonicalTimer?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            let intentsEqual: Bool
            switch (lhs.lastIntent, rhs.lastIntent) {
            case (nil, nil):
                intentsEqual = true
            case let (.some(lhs), .some(rhs)):
                intentsEqual = lhs.type == rhs.type
                    && lhs.commandId == rhs.commandId
                    && wireDatesEqual(lhs.occurredAt, rhs.occurredAt)
            default:
                intentsEqual = false
            }
            return lhs.id == rhs.id
                && lhs.taskId == rhs.taskId
                && lhs.phase == rhs.phase
                && lhs.status == rhs.status
                && lhs.plannedDurationMs == rhs.plannedDurationMs
                && lhs.elapsedAtAnchorMs == rhs.elapsedAtAnchorMs
                && wireDatesEqual(lhs.anchorAt, rhs.anchorAt)
                && lhs.startedByDeviceId == rhs.startedByDeviceId
                && intentsEqual
        default:
            return false
        }
    }

    func validated(for input: CoreReconcileInput) throws -> Self {
        let response = input.response
        let localTimerIDs = Set(input.local.commands.map(\.id))
        let localTaskIDs = Set(input.local.taskOperations.map(\.id))
        let localDurationIDs = Set(input.local.durationOperations.map(\.id))
        let localAutoStartIDs = Set(input.local.autoStartOperations.map(\.id))
        let localSelectedTaskIDs = Set(input.local.selectedTaskOperations.map(\.id))
        let pendingTimerIDs = Set(pending.map(\.id))
        let promotedIDs = Set(promotedTimerOperationIds)
        let droppedIDs = Set(droppedTimerOperationIds)
        let structuralChecks: [(String, Bool)] = [
            ("revision", revision == response.revision),
            ("baseTimer", Self.wireTimersEqual(baseTimer, response.canonicalTimer)),
            ("baseHistory", Self.wireHistoriesEqual(baseHistory, response.history)),
            ("baseTasks", baseTasks == response.tasks),
            ("baseDurations", baseDurationsMs == response.durationsMs),
            ("baseAutoStart", baseAutoStartBreaks == response.autoStartBreaks),
            ("baseSelectedTask", baseSelectedTaskId == response.selectedTaskId),
            ("canonicalSnapshot", CanonicalSnapshotValidation.isValid(timer: timer, history: history, tasks: tasks, durations: durationsMs, selectedTaskId: selectedTaskId)),
            ("pendingTimerUnique", pendingTimerIDs.count == pending.count),
            ("pendingTaskUnique", Set(pendingTaskOperations.map(\.id)).count == pendingTaskOperations.count),
            ("pendingDurationUnique", Set(pendingDurationOperations.map(\.id)).count == pendingDurationOperations.count),
            ("pendingAutoStartUnique", Set(pendingAutoStartOperations.map(\.id)).count == pendingAutoStartOperations.count),
            ("pendingSelectedTaskUnique", Set(pendingSelectedTaskOperations.map(\.id)).count == pendingSelectedTaskOperations.count),
            ("pendingTimerSubset", pendingTimerIDs.isSubset(of: localTimerIDs)),
            ("pendingTaskSubset", Set(pendingTaskOperations.map(\.id)).isSubset(of: localTaskIDs)),
            ("pendingDurationSubset", Set(pendingDurationOperations.map(\.id)).isSubset(of: localDurationIDs)),
            ("pendingAutoStartSubset", Set(pendingAutoStartOperations.map(\.id)).isSubset(of: localAutoStartIDs)),
            ("pendingSelectedTaskSubset", Set(pendingSelectedTaskOperations.map(\.id)).isSubset(of: localSelectedTaskIDs)),
            ("promotedSubset", promotedIDs.isSubset(of: localTimerIDs)),
            ("droppedSubset", droppedIDs.isSubset(of: localTimerIDs)),
            ("promotedDroppedDisjoint", promotedIDs.isDisjoint(with: droppedIDs)),
            ("droppedTimerUnique", Set(droppedTimerIds).count == droppedTimerIds.count),
            ("dependencyUnique", Set(pendingTimerDependencies.map(\.operationId)).count == pendingTimerDependencies.count),
            ("dependencyRetained", pendingTimerDependencies.allSatisfy({ dependency in
                pendingTimerIDs.contains(dependency.operationId)
                    && pendingTimerIDs.contains(dependency.dependsOnOperationId)
            }))
        ]
        let failedChecks = structuralChecks.filter { !$0.1 }.map(\.0)
        guard failedChecks.isEmpty else {
            throw SharedCoreError.invalidResponse(
                "reconcile.rebase.v1 output failed structural validation: \(failedChecks.joined(separator: ", "))"
            )
        }
        return self
    }

    func nativePendingCommands(deviceId: String) throws -> [TimerCommand] {
        try pending.map { try $0.native(deviceId: deviceId) }
    }

    func nativePendingTaskOperations(deviceId: String) throws -> [TaskOperation] {
        try pendingTaskOperations.map { try $0.native(deviceId: deviceId) }
    }

    func nativePendingDurationOperations(deviceId: String) throws -> [DurationOperation] {
        try pendingDurationOperations.map { try $0.native(deviceId: deviceId) }
    }

    func nativePendingAutoStartOperations(deviceId: String) throws -> [AutoStartOperation] {
        try pendingAutoStartOperations.map { try $0.native(deviceId: deviceId) }
    }

    func nativePendingSelectedTaskOperations(deviceId: String) throws -> [SelectedTaskOperation] {
        try pendingSelectedTaskOperations.map { try $0.native(deviceId: deviceId) }
    }
}
