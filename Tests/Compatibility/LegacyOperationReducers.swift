import Foundation
@testable import Pomodorough

// Test-only native operation references retained for exact legacy fixture expectations.
enum TaskReducer {
    static func applying(_ operations: [TaskOperation], to baseTasks: [FocusTask]) -> [FocusTask] {
        operations.sorted(by: precedes).reduce(into: baseTasks) { tasks, operation in
            guard let taskID = UUID(uuidString: operation.taskId) else { return }
            switch operation.type {
            case .delete:
                tasks.removeAll { $0.id == taskID }
            case .upsert:
                guard let title = operation.title,
                      let task = FocusTask(title: title),
                      task.id == taskID else { return }
                tasks.removeAll { $0.id == taskID }
                tasks.append(task)
            }
        }
    }

    private static func precedes(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum DurationReducer {
    static func applying(_ operations: [DurationOperation], to base: DurationValues) -> DurationValues {
        operations.sorted(by: precedes).reduce(into: base) { durations, operation in
            guard operation.isValid else { return }
            durations.setDurationMs(operation.durationMs, for: operation.phase)
        }
    }

    private static func precedes(_ lhs: DurationOperation, _ rhs: DurationOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum AutoStartReducer {
    static func applying(_ operations: [AutoStartOperation], to base: Bool) -> Bool {
        operations.sorted(by: precedes).reduce(base) { enabled, operation in
            operation.isValid ? operation.enabled : enabled
        }
    }

    private static func precedes(_ lhs: AutoStartOperation, _ rhs: AutoStartOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum SelectedTaskReducer {
    static func applying(_ operations: [SelectedTaskOperation], to base: UUID?) -> UUID? {
        operations.sorted(by: precedes).reduce(base) { selectedTaskID, operation in
            guard operation.isValid else { return selectedTaskID }
            return operation.taskId.flatMap(UUID.init(uuidString:))
        }
    }

    private static func precedes(_ lhs: SelectedTaskOperation, _ rhs: SelectedTaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
