import Foundation
@testable import Pomodorough

// Test-only native clock/rebase reference retained for exact legacy expectations.
struct PersistedClockValue: Equatable, Sendable {
    let wallMs: Int64
    let counter: Int64
}

struct PendingOperationRebaseResult: Equatable, Sendable {
    let queue: PersistedPendingOperationQueue
    let clock: PersistedClockValue
}

extension PersistedPendingOperationQueue {
    var maximumClock: PersistedClockValue? {
        let clocks = commands.map { PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + taskOperations.map { PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + durationOperations.map { PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + autoStartOperations.map { PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + selectedTaskOperations.map { PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
        return clocks.filter { $0.wallMs > 0 }.max {
            ($0.wallMs, $0.counter) < ($1.wallMs, $1.counter)
        }
    }
}

extension PersistedTimerState {
    mutating func rebasePendingOperations(
        afterServerWallMs serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date
    ) throws {
        let result = try PersistedQueueReconciliation.rebase(
            PersistedPendingOperationQueue(state: self),
            currentClock: PersistedClockValue(wallMs: hlcWallMs, counter: hlcCounter),
            afterServerClock: PersistedClockValue(wallMs: serverWallMs, counter: serverCounter),
            serverTime: serverTime
        )
        pendingCommands = result.queue.commands
        pendingTaskOperations = result.queue.taskOperations
        pendingDurationOperations = result.queue.durationOperations
        pendingAutoStartOperations = result.queue.autoStartOperations
        pendingSelectedTaskOperations = result.queue.selectedTaskOperations
        hlcWallMs = result.clock.wallMs
        hlcCounter = result.clock.counter
    }
}

extension PersistedQueueReconciliation {
    static func rebase(
        _ queue: PersistedPendingOperationQueue,
        currentClock: PersistedClockValue,
        afterServerClock serverClock: PersistedClockValue,
        serverTime: Date
    ) throws -> PendingOperationRebaseResult {
        let context = try PendingRebaseContext(serverClock: serverClock, serverTime: serverTime)
        let rebased = try PersistedPendingOperationQueue(
            commands: rebaseCommands(queue.commands, using: context),
            taskOperations: rebaseTasks(queue.taskOperations, using: context),
            durationOperations: rebaseDurations(queue.durationOperations, using: context),
            autoStartOperations: rebaseAutoStart(queue.autoStartOperations, using: context),
            selectedTaskOperations: rebaseSelectedTasks(queue.selectedTaskOperations, using: context)
        )
        let pendingClock = rebased.maximumClock ?? serverClock
        let mergedClock = isClock(currentClock, greaterThan: pendingClock) ? currentClock : pendingClock
        return PendingOperationRebaseResult(queue: rebased, clock: mergedClock)
    }
}

private extension PersistedQueueReconciliation {
    static func rebaseCommands(
        _ commands: [TimerCommand],
        using context: PendingRebaseContext
    ) throws -> [TimerCommand] {
        let replacements = try context.replacements(for: commands.sorted(by: commandOrder).map {
            ($0.id, PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter))
        })
        return try commands.map { command in
            guard let clock = replacements[command.id] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: command.taskId,
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: try context.rebasedDate(command.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
    }

    static func rebaseTasks(
        _ operations: [TaskOperation],
        using context: PendingRebaseContext
    ) throws -> [TaskOperation] {
        let replacements = try context.replacements(for: operations.sorted(by: taskOrder).map {
            ($0.id, PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter))
        })
        return try operations.map { operation in
            guard let clock = replacements[operation.id] else { return operation }
            return TaskOperation(
                id: operation.id,
                taskId: operation.taskId,
                type: operation.type,
                title: operation.title,
                occurredAt: try context.rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }
    }

    static func rebaseDurations(
        _ operations: [DurationOperation],
        using context: PendingRebaseContext
    ) throws -> [DurationOperation] {
        let replacements = try context.replacements(for: operations.sorted(by: durationOrder).map {
            ($0.id, PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter))
        })
        return try operations.map { operation in
            guard let clock = replacements[operation.id] else { return operation }
            return DurationOperation(
                id: operation.id,
                phase: operation.phase,
                durationMs: operation.durationMs,
                occurredAt: try context.rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }
    }

    static func rebaseAutoStart(
        _ operations: [AutoStartOperation],
        using context: PendingRebaseContext
    ) throws -> [AutoStartOperation] {
        let replacements = try context.replacements(for: operations.sorted(by: autoStartOrder).map {
            ($0.id.uuidString, PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter))
        })
        return try operations.map { operation in
            guard let clock = replacements[operation.id.uuidString] else { return operation }
            return AutoStartOperation(
                id: operation.id,
                deviceId: operation.deviceId,
                enabled: operation.enabled,
                occurredAt: try context.rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }
    }

    static func rebaseSelectedTasks(
        _ operations: [SelectedTaskOperation],
        using context: PendingRebaseContext
    ) throws -> [SelectedTaskOperation] {
        let replacements = try context.replacements(for: operations.sorted(by: selectedTaskOrder).map {
            ($0.id.uuidString, PersistedClockValue(wallMs: $0.hlcWallMs, counter: $0.hlcCounter))
        })
        return try operations.map { operation in
            guard let clock = replacements[operation.id.uuidString] else { return operation }
            return SelectedTaskOperation(
                id: operation.id,
                deviceId: operation.deviceId,
                taskId: operation.taskId,
                occurredAt: try context.rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }
    }
}

private extension PersistedQueueReconciliation {
    static func isClock(_ lhs: PersistedClockValue, greaterThan rhs: PersistedClockValue) -> Bool {
        (lhs.wallMs, lhs.counter) > (rhs.wallMs, rhs.counter)
    }

    static func commandOrder(_ lhs: TimerCommand, _ rhs: TimerCommand) -> Bool {
        if lhs.deviceSequence != rhs.deviceSequence { return lhs.deviceSequence < rhs.deviceSequence }
        return lhs.id < rhs.id
    }

    static func taskOrder(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }

    static func durationOrder(_ lhs: DurationOperation, _ rhs: DurationOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }

    static func autoStartOrder(_ lhs: AutoStartOperation, _ rhs: AutoStartOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func selectedTaskOrder(
        _ lhs: SelectedTaskOperation,
        _ rhs: SelectedTaskOperation
    ) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct PendingRebaseContext {
    let minimumMs: Int64
    let maximumMs: Int64
    let canonicalClock: PersistedClockValue

    init(serverClock: PersistedClockValue, serverTime: Date) throws {
        guard let serverTimeMs = WireBounds.physicalMilliseconds(for: serverTime),
              WireBounds.isValidClock(wallMs: serverClock.wallMs, counter: serverClock.counter),
              WireBounds.isWithinClockSkew(wallMs: serverClock.wallMs, occurredAt: serverTime) else {
            throw AppError.invalidResponse
        }
        minimumMs = max(1, serverTimeMs - WireBounds.maxClockSkewMs)
        maximumMs = min(WireBounds.maxSafeInteger, serverTimeMs + WireBounds.maxClockSkewMs)
        canonicalClock = serverClock
    }

    func replacements(
        for operations: [(id: String, clock: PersistedClockValue)]
    ) throws -> [String: PersistedClockValue] {
        var cursor = canonicalClock
        var result: [String: PersistedClockValue] = [:]
        for operation in operations where operation.clock.wallMs > 0 {
            if (minimumMs...maximumMs).contains(operation.clock.wallMs),
               isClock(operation.clock, greaterThan: cursor) {
                cursor = operation.clock
            } else {
                cursor = try nextClock(after: cursor)
                result[operation.id] = cursor
            }
        }
        return result
    }

    func rebasedDate(_ original: Date, clock: PersistedClockValue) throws -> Date {
        if let originalMs = WireBounds.physicalMilliseconds(for: original),
           (minimumMs...maximumMs).contains(originalMs),
           abs(clock.wallMs - originalMs) <= WireBounds.maxClockSkewMs {
            return original
        }
        guard let date = WireBounds.date(milliseconds: clock.wallMs) else {
            throw AppError.invalidResponse
        }
        return date
    }

    private func nextClock(after clock: PersistedClockValue) throws -> PersistedClockValue {
        if clock.counter < WireBounds.maxSafeInteger {
            return PersistedClockValue(wallMs: clock.wallMs, counter: clock.counter + 1)
        }
        guard clock.wallMs < maximumMs else { throw AppError.invalidResponse }
        return PersistedClockValue(wallMs: clock.wallMs + 1, counter: 0)
    }

    private func isClock(
        _ lhs: PersistedClockValue,
        greaterThan rhs: PersistedClockValue
    ) -> Bool {
        (lhs.wallMs, lhs.counter) > (rhs.wallMs, rhs.counter)
    }
}
