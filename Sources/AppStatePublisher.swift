import Foundation

struct AppStatePublisher: Sendable {
    struct Snapshot: Sendable {
        let canonicalTimer: CanonicalTimer?
        let history: [HistoryItem]
        let tasks: [FocusTask]
        let state: PersistedTimerState
    }

    enum Effect: Equatable, Sendable {
        case cancelAlarm(timerID: String, reportsError: Bool)
    }

    struct Publication: Equatable, Sendable {
        let state: PersistedTimerState
        let canonicalTimer: CanonicalTimer?
        let history: [HistoryItem]
        let tasks: [FocusTask]
        let autoStartBreaks: Bool
        let selectedTaskID: UUID?
        let completionAlertTimerID: String?
        let completionQueuedFor: String?
        let effects: [Effect]
    }

    struct CompletionPresentation: Equatable, Sendable {
        let alertTimerID: String?
        let effects: [Effect]
    }

    func publication(
        output: CoreProjectionOutput,
        state: PersistedTimerState,
        completionAlertTimerID: String?,
        completionQueuedFor: String?
    ) -> Publication {
        var publishedState = state
        publishedState.settings.durationsMs = output.durationsMs
        publishedState.mergeKnownTasks(output.tasks)
        let completion = completionPresentation(
            alertTimerID: completionAlertTimerID,
            currentTimer: output.canonicalTimer
        )
        return Publication(
            state: publishedState,
            canonicalTimer: output.canonicalTimer,
            history: output.history,
            tasks: output.tasks,
            autoStartBreaks: output.autoStartBreaks,
            selectedTaskID: output.selectedTaskId.flatMap(UUID.init(uuidString:)),
            completionAlertTimerID: completion.alertTimerID,
            completionQueuedFor: output.canonicalTimer?.status == .running
                ? completionQueuedFor
                : nil,
            effects: completion.effects
        )
    }

    func completionPresentation(
        alertTimerID: String?,
        currentTimer: CanonicalTimer?
    ) -> CompletionPresentation {
        guard let alertTimerID,
              let currentTimer,
              currentTimer.id != alertTimerID,
              currentTimer.status == .running || currentTimer.status == .paused else {
            return CompletionPresentation(alertTimerID: alertTimerID, effects: [])
        }
        return CompletionPresentation(
            alertTimerID: nil,
            effects: [.cancelAlarm(timerID: alertTimerID, reportsError: false)]
        )
    }

    func fallbackPublication(from state: PersistedTimerState) -> Publication {
        let timer = (try? state.physicalCanonicalTimer(state.canonicalTimer))
            ?? state.canonicalTimer
        let tasks = state.tasks
        return Publication(
            state: state,
            canonicalTimer: timer,
            history: state.history,
            tasks: tasks,
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskID: state.selectedTaskID.flatMap { selected in
                tasks.contains(where: { $0.id == selected }) ? selected : nil
            },
            completionAlertTimerID: nil,
            completionQueuedFor: nil,
            effects: []
        )
    }

    func task(
        forTimerID timerID: String,
        snapshot: Snapshot
    ) -> FocusTask? {
        let taskID = snapshot.canonicalTimer.flatMap { $0.id == timerID ? $0.taskId : nil }
            ?? snapshot.history.first(where: { $0.timerId == timerID })?.taskId
            ?? snapshot.state.pendingCommands.first(where: {
                $0.timerId == timerID && $0.type == .start
            })?.taskId
        let uuid = taskID.flatMap(UUID.init(uuidString:))
            ?? snapshot.state.legacyTaskAssignments[timerID]
        guard let uuid else { return nil }
        return snapshot.tasks.first(where: { $0.id == uuid })
            ?? snapshot.state.knownTasks.first(where: { $0.id == uuid })
    }

    func taskSummaries(
        for date: Date,
        calendar: Calendar,
        snapshot: Snapshot
    ) -> [TaskDailySummary] {
        var totals: [UUID: (finished: Int, timeMs: Int64)] = [:]
        for item in snapshot.history {
            guard item.phase == .focus,
                  item.status == "completed",
                  let completedAt = item.completedAt,
                  calendar.isDate(completedAt, inSameDayAs: date),
                  let uuid = item.taskId.flatMap(UUID.init(uuidString:))
                    ?? snapshot.state.legacyTaskAssignments[item.timerId] else { continue }
            let current = totals[uuid] ?? (0, 0)
            totals[uuid] = (
                current.finished + 1,
                current.timeMs + item.plannedDurationMs
            )
        }
        return snapshot.tasks.map { task in
            let total = totals[task.id] ?? (0, 0)
            return TaskDailySummary(
                task: task,
                finishedPomodoros: total.finished,
                timeSpentMs: total.timeMs
            )
        }
    }

    func completedFocusSummaries(
        snapshot: Snapshot
    ) -> [CompletedFocusSummary] {
        let taskByID = (snapshot.state.knownTasks + snapshot.tasks).reduce(
            into: [UUID: FocusTask]()
        ) { lookup, task in
            lookup[task.id] = task
        }
        let legacyAssignments = snapshot.state.legacyTaskAssignments
        return HistoryAnalytics.completedFocusSummaries(
            from: snapshot.history,
            taskIDForItem: { item in
                item.taskId ?? legacyAssignments[item.timerId]?.uuidString
            },
            taskForItem: { item in
                let taskID = item.taskId.flatMap(UUID.init(uuidString:))
                    ?? legacyAssignments[item.timerId]
                return taskID.flatMap { taskByID[$0] }
            }
        )
    }

    func taskContext(
        for item: HistoryItem,
        snapshot: Snapshot
    ) -> String {
        let taskID = item.taskId.flatMap(UUID.init(uuidString:))
            ?? snapshot.state.legacyTaskAssignments[item.timerId]
        let taskByID = (snapshot.state.knownTasks + snapshot.tasks).reduce(
            into: [UUID: FocusTask]()
        ) { lookup, task in
            lookup[task.id] = task
        }
        return HistoryAnalytics.taskContext(for: item) { _ in
            taskID.flatMap { taskByID[$0] }
        }
    }
}
