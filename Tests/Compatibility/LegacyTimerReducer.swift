import Foundation
@testable import Pomodorough

// Test-only native timer reference retained for exact legacy fixture expectations.
enum TimerReducer {
    private struct ReductionState {
        var timer: CanonicalTimer?
        var history: [HistoryItem]
        var sessions: [String: (timer: CanonicalTimer, historyID: String)]
    }

    private struct CommandContext {
        let timer: CanonicalTimer?
        let historyID: String?
    }

    static func projectingTimeCompletion(
        _ timer: CanonicalTimer?,
        history: [HistoryItem],
        at date: Date
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        let projected = autoCompleting(timer, history: history, at: date)
        return (projected.0, orderedHistory(projected.1))
    }

    static func breakPhase(afterCompletedFocusCount count: Int) -> TimerPhase {
        count > 0 && count.isMultiple(of: 4) ? .longBreak : .shortBreak
    }

    static func applying(
        _ commands: [TimerCommand],
        to canonical: CanonicalTimer?,
        history canonicalHistory: [HistoryItem]
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        // Native optimistic commands all belong to this client device, so the
        // device-ID component of the Rust total-order tuple is constant here.
        let ordered = commands.sorted {
            if $0.hlcWallMs != $1.hlcWallMs { return $0.hlcWallMs < $1.hlcWallMs }
            if $0.hlcCounter != $1.hlcCounter { return $0.hlcCounter < $1.hlcCounter }
            return $0.id < $1.id
        }
        return applyingInProvidedOrder(ordered, to: canonical, history: canonicalHistory)
    }

    static func applyingInProvidedOrder(
        _ ordered: [TimerCommand],
        to canonical: CanonicalTimer?,
        history canonicalHistory: [HistoryItem]
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        var sessions: [String: (timer: CanonicalTimer, historyID: String)] = [:]
        for item in canonicalHistory {
            if let timer = target(item.timerId, current: nil, history: [item], at: item.endedAt ?? item.completedAt ?? .distantPast) {
                sessions[item.timerId] = (timer, item.id)
            }
        }
        if let canonical { sessions[canonical.id] = (canonical, canonical.id) }
        var state = ReductionState(
            timer: canonical,
            history: orderedHistory(canonicalHistory),
            sessions: sessions
        )
        for command in ordered { apply(command, to: &state) }
        return (state.timer, orderedHistory(state.history))
    }
}

extension TimerReducer {
    private static func apply(_ command: TimerCommand, to state: inout ReductionState) {
        let context = commandContext(command, state: state)
        let inputHistory = historyForApplying(command, context: context, state: state)
        let applied = apply(command, to: state.timer, history: inputHistory)
        state.timer = applied.0
        state.history = restoringHistoryIDs(applied.1, sessions: state.sessions)
        if command.type == .clear, let existing = context.timer {
            state.sessions[command.timerId] = (existing, context.historyID ?? existing.id)
        }
        saveCurrentSession(command, context: context, state: &state)
    }

    private static func commandContext(
        _ command: TimerCommand,
        state: ReductionState
    ) -> CommandContext {
        let item = state.history.first { $0.timerId == command.timerId }
        let saved = state.sessions[command.timerId]
        let timer = state.timer?.id == command.timerId
            ? state.timer
            : item.flatMap {
                target(command.timerId, current: nil, history: [$0], at: command.occurredAt)
            } ?? saved?.timer
        return CommandContext(timer: timer, historyID: item?.id ?? saved?.historyID ?? timer?.id)
    }

    private static func historyForApplying(
        _ command: TimerCommand,
        context: CommandContext,
        state: ReductionState
    ) -> [HistoryItem] {
        var history = state.history
        guard command.type != .clear,
              state.timer?.id != command.timerId,
              !history.contains(where: { $0.timerId == command.timerId }),
              let timer = context.timer else { return history }
        history.append(HistoryItem(
            id: context.historyID ?? timer.id,
            timerId: timer.id,
            commandId: timer.lastIntent?.commandId,
            taskId: timer.taskId,
            phase: timer.phase,
            status: timer.status.rawValue,
            plannedDurationMs: timer.plannedDurationMs,
            completedAt: timer.status == .completed ? timer.anchorAt : nil,
            endedAt: timer.anchorAt
        ))
        return history
    }

    private static func restoringHistoryIDs(
        _ history: [HistoryItem],
        sessions: [String: (timer: CanonicalTimer, historyID: String)]
    ) -> [HistoryItem] {
        history.map { item in
            guard item.id == item.timerId,
                  let historyID = sessions[item.timerId]?.historyID,
                  historyID != item.id else { return item }
            return HistoryItem(
                id: historyID,
                timerId: item.timerId,
                commandId: item.commandId,
                taskId: item.taskId,
                phase: item.phase,
                status: item.status,
                plannedDurationMs: item.plannedDurationMs,
                completedAt: item.completedAt,
                endedAt: item.endedAt
            )
        }
    }

    private static func saveCurrentSession(
        _ command: TimerCommand,
        context: CommandContext,
        state: inout ReductionState
    ) {
        guard let timer = state.timer else { return }
        let historyID: String
        if command.type == .start, timer.id == command.timerId {
            historyID = timer.id
        } else if timer.id == command.timerId {
            historyID = context.historyID ?? timer.id
        } else {
            historyID = state.sessions[timer.id]?.historyID
                ?? state.history.first(where: { $0.timerId == timer.id })?.id
                ?? timer.id
        }
        state.sessions[timer.id] = (timer, historyID)
    }

    static func apply(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let projected = autoCompleting(timer, history: history, at: command.occurredAt)
        let transitioned = applyTransition(command, to: projected.0, history: projected.1)
        return (transitioned.0, orderedHistory(transitioned.1))
    }

    private static func orderedHistory(_ history: [HistoryItem]) -> [HistoryItem] {
        history.sorted { lhs, rhs in
            let lhsDate = lhs.completedAt ?? lhs.endedAt ?? .distantPast
            let rhsDate = rhs.completedAt ?? rhs.endedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.timerId.utf8.lexicographicallyPrecedes(rhs.timerId.utf8)
        }
    }

    private static func applyTransition(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let intent = TimerIntent(
            type: command.type,
            commandId: command.id,
            occurredAt: command.occurredAt,
            deviceId: nil
        )
        switch command.type {
        case .start:
            return startTransition(command, timer: timer, history: history, intent: intent)
        case .pause:
            return activeTransition(command, status: .paused, timer: timer, history: history, intent: intent)
        case .resume:
            return activeTransition(command, status: .running, timer: timer, history: history, intent: intent)
        case .finish:
            return terminalTransition(command, status: .completed, timer: timer, history: history, intent: intent)
        case .cancel:
            return terminalTransition(command, status: .cancelled, timer: timer, history: history, intent: intent)
        case .clear:
            guard target(command.timerId, current: timer, history: history, at: command.occurredAt) != nil else { return (timer, history) }
            return (timer?.id == command.timerId ? nil : timer, history)
        }
    }

    private static func startTransition(
        _ command: TimerCommand,
        timer: CanonicalTimer?,
        history: [HistoryItem],
        intent: TimerIntent
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let nextHistory = preservingDisplaced(
            current: timer,
            replacementId: command.timerId,
            history: history.filter { $0.timerId != command.timerId },
            command: command
        )
        return (CanonicalTimer(
            id: command.timerId,
            taskId: command.taskId,
            phase: command.phase,
            status: .running,
            plannedDurationMs: command.plannedDurationMs,
            elapsedAtAnchorMs: 0,
            anchorAt: command.occurredAt,
            lastIntent: intent
        ), nextHistory)
    }

    private static func activeTransition(
        _ command: TimerCommand,
        status: CanonicalTimer.Status,
        timer: CanonicalTimer?,
        history: [HistoryItem],
        intent: TimerIntent
    ) -> (CanonicalTimer?, [HistoryItem]) {
        guard let target = target(
            command.timerId,
            current: timer,
            history: history,
            at: command.occurredAt
        ) else { return (timer, history) }
        return (
            updated(
                target,
                status: status,
                elapsed: command.observedElapsedMs,
                at: command.occurredAt,
                intent: intent
            ),
            activating(target, current: timer, history: history, command: command)
        )
    }

    private static func terminalTransition(
        _ command: TimerCommand,
        status: CanonicalTimer.Status,
        timer: CanonicalTimer?,
        history: [HistoryItem],
        intent: TimerIntent
    ) -> (CanonicalTimer?, [HistoryItem]) {
        guard let target = target(
            command.timerId,
            current: timer,
            history: history,
            at: command.occurredAt
        ) else { return (timer, history) }
        let elapsed = status == .completed ? target.plannedDurationMs : command.observedElapsedMs
        let transitioned = updated(target, status: status, elapsed: elapsed, at: command.occurredAt, intent: intent)
        let item = HistoryItem(
            id: history.first(where: { $0.timerId == command.timerId })?.id ?? command.timerId,
            timerId: command.timerId,
            commandId: command.id,
            taskId: target.taskId,
            phase: target.phase,
            status: status.rawValue,
            plannedDurationMs: target.plannedDurationMs,
            completedAt: status == .completed ? command.occurredAt : nil,
            endedAt: command.occurredAt
        )
        let priorHistory = activating(target, current: timer, history: history, command: command)
        return (transitioned, [item] + priorHistory)
    }

    private static func target(
        _ id: String,
        current: CanonicalTimer?,
        history: [HistoryItem],
        at date: Date
    ) -> CanonicalTimer? {
        if let current, current.id == id { return current }
        guard let item = history.first(where: { $0.timerId == id }),
              let status = CanonicalTimer.Status(rawValue: item.status) else { return nil }
        return CanonicalTimer(
            id: item.timerId,
            taskId: item.taskId,
            phase: item.phase,
            status: status,
            plannedDurationMs: item.plannedDurationMs,
            elapsedAtAnchorMs: status == .completed ? item.plannedDurationMs : 0,
            anchorAt: item.endedAt ?? date,
            lastIntent: nil
        )
    }

    private static func preservingDisplaced(
        current: CanonicalTimer?,
        replacementId: String,
        history: [HistoryItem],
        command: TimerCommand
    ) -> [HistoryItem] {
        guard let current, current.id != replacementId else { return history }
        var result = history
        if current.status == .running || current.status == .paused {
            guard !result.contains(where: {
                $0.commandId == command.id && $0.timerId == current.id
            }) else { return result }
            let historyID = result.first(where: { $0.timerId == current.id })?.id ?? current.id
            result.removeAll { $0.timerId == current.id }
            result.insert(HistoryItem(
                id: historyID,
                timerId: current.id,
                commandId: command.id,
                taskId: current.taskId,
                phase: current.phase,
                status: CanonicalTimer.Status.superseded.rawValue,
                plannedDurationMs: current.plannedDurationMs,
                completedAt: nil,
                endedAt: command.occurredAt
            ), at: 0)
        } else if !result.contains(where: { $0.timerId == current.id }) {
            result.insert(HistoryItem(
                id: current.id,
                timerId: current.id,
                commandId: current.lastIntent?.commandId,
                taskId: current.taskId,
                phase: current.phase,
                status: current.status.rawValue,
                plannedDurationMs: current.plannedDurationMs,
                completedAt: current.status == .completed ? current.anchorAt : nil,
                endedAt: current.anchorAt
            ), at: 0)
        }
        return result
    }

    private static func activating(
        _ target: CanonicalTimer,
        current: CanonicalTimer?,
        history: [HistoryItem],
        command: TimerCommand
    ) -> [HistoryItem] {
        preservingDisplaced(
            current: current,
            replacementId: target.id,
            history: history.filter { $0.timerId != target.id },
            command: command
        )
    }

    private static func autoCompleting(
        _ timer: CanonicalTimer?,
        history: [HistoryItem],
        at date: Date
    ) -> (CanonicalTimer?, [HistoryItem]) {
        guard let timer, timer.status == .running else { return (timer, history) }
        let planned = max(0, timer.plannedDurationMs)
        let stored = min(planned, max(0, timer.elapsedAtAnchorMs))
        let elapsedAtDate = TimeInterval(stored) / 1_000 + max(0, date.timeIntervalSince(timer.anchorAt))
        guard elapsedAtDate >= TimeInterval(planned) / 1_000 else { return (timer, history) }

        let completedAt = timer.anchorAt.addingTimeInterval(TimeInterval(planned - stored) / 1_000)
        let completed = CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: .completed,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: timer.plannedDurationMs,
            anchorAt: completedAt,
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: timer.lastIntent
        )
        guard !history.contains(where: { $0.timerId == timer.id }) else { return (completed, history) }
        let completion = HistoryItem(
            id: timer.id,
            timerId: timer.id,
            commandId: nil,
            taskId: timer.taskId,
            phase: timer.phase,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: timer.plannedDurationMs,
            completedAt: completedAt,
            endedAt: completedAt
        )
        return (completed, [completion] + history)
    }

    private static func updated(
        _ timer: CanonicalTimer,
        status: CanonicalTimer.Status,
        elapsed: Int64,
        at date: Date,
        intent: TimerIntent
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: min(timer.plannedDurationMs, max(0, elapsed)),
            anchorAt: date,
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: intent
        )
    }
}
