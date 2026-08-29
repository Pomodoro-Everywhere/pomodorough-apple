import Foundation

enum IrohSnapshotValidation {
    static func isValid(
        timer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durations: DurationValues
    ) -> Bool {
        durations.isValid
            && (timer.map(isValidTimer) ?? true)
            && history.allSatisfy(isValidHistory)
            && tasks.allSatisfy(\.isValid)
            && Set(history.map(\.id)).count == history.count
            && Set(history.map(\.timerId)).count == history.count
            && Set(tasks.map(\.id)).count == tasks.count
    }

    private static func isValidTimer(_ timer: CanonicalTimer) -> Bool {
        IrohProtocolV1.isValidIdentifier(timer.id)
            && (timer.taskId.map(IrohProtocolV1.isValidTaskID) ?? true)
            && (60_000...14_400_000).contains(timer.plannedDurationMs)
            && (0...timer.plannedDurationMs).contains(timer.elapsedAtAnchorMs)
            && WireBounds.physicalMilliseconds(for: timer.anchorAt) != nil
            && (timer.startedByDeviceId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && (timer.lastIntent?.isValid ?? true)
    }

    private static func isValidHistory(_ item: HistoryItem) -> Bool {
        let hasValidTerminalDate: Bool
        switch item.status {
        case CanonicalTimer.Status.completed.rawValue:
            hasValidTerminalDate = item.completedAt != nil
        case CanonicalTimer.Status.cancelled.rawValue,
             CanonicalTimer.Status.superseded.rawValue:
            hasValidTerminalDate = item.completedAt == nil && item.endedAt != nil
        default:
            hasValidTerminalDate = false
        }
        return IrohProtocolV1.isValidIdentifier(item.id)
            && IrohProtocolV1.isValidIdentifier(item.timerId)
            && (item.commandId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && (item.taskId.map(IrohProtocolV1.isValidTaskID) ?? true)
            && (60_000...14_400_000).contains(item.plannedDurationMs)
            && hasValidTerminalDate
            && item.date.flatMap(WireBounds.physicalMilliseconds(for:)) != nil
            && (item.endedAt == nil || item.endedAt.flatMap(WireBounds.physicalMilliseconds(for:)) != nil)
    }
}
