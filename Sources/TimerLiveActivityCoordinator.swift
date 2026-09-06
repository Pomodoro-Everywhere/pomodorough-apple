#if os(iOS)
import ActivityKit
import AlarmKit
import OSLog
import SwiftUI

extension TimerActivityAttributes.ContentState {
    init(timer: CanonicalTimer, taskTitle: String?) {
        let remaining = max(0, timer.plannedDuration - Double(timer.elapsedAtAnchorMs) / 1_000)
        phase = timer.phase.rawValue
        self.taskTitle = taskTitle
        startedAt = timer.anchorAt.addingTimeInterval(-Double(timer.elapsedAtAnchorMs) / 1_000)
        endsAt = timer.anchorAt.addingTimeInterval(remaining)
        self.remaining = remaining
        isPaused = timer.status == .paused
    }
}

@MainActor
final class TimerLiveActivityCoordinator {
    private var tail: Task<Void, Never>?
    private var trackedActivityID: String?
    private var trackedTimerID: String?
    private var dismissedTimerID: String?
    private let logger = Logger(subsystem: "me.egigoka.pomodorough", category: "LiveActivity")

    func synchronize(timer: CanonicalTimer?, taskTitle: String?, canStart: Bool) {
        let previous = tail
        tail = Task {
            await previous?.value
            await reconcile(timer: timer, taskTitle: taskTitle, canStart: canStart)
        }
    }

    private func reconcile(timer: CanonicalTimer?, taskTitle: String?, canStart: Bool) async {
        pruneDismissedTracking()
        let desired = resolveDesiredTimer(from: timer)
        let matching = await takeMatchingActivity(keeping: desired?.id)
        guard let desired else { return }
        let state = TimerActivityAttributes.ContentState(timer: desired, taskTitle: taskTitle)
        let content = ActivityContent(state: state, staleDate: state.isPaused ? nil : state.endsAt)
        if let matching {
            trackedActivityID = matching.id
            trackedTimerID = desired.id
            if matching.content.state != state || matching.content.staleDate != content.staleDate {
                await matching.update(content)
            }
        } else if canStart && ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                trackedActivityID = try Activity.request(
                    attributes: TimerActivityAttributes(timerID: desired.id),
                    content: content,
                    pushType: nil
                ).id
                trackedTimerID = desired.id
            } catch {
                // A denied Live Activity must never prevent timer or alarm operation.
                logger.error("Could not start timer Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pruneDismissedTracking() {
        if let trackedActivityID,
           !Activity<TimerActivityAttributes>.activities.contains(where: {
               $0.id == trackedActivityID && ($0.activityState == .active || $0.activityState == .stale)
           }) {
            dismissedTimerID = trackedTimerID
            self.trackedActivityID = nil
        }
    }

    private func resolveDesiredTimer(from timer: CanonicalTimer?) -> CanonicalTimer? {
        guard let timer else { return nil }
        let active = timer.status == .running || timer.status == .paused
        if !active || timer.remaining(at: .now) <= 0
            || hasNativeAlarm(timer.id) || dismissedTimerID == timer.id {
            return nil
        }
        return timer
    }

    private func takeMatchingActivity(
        keeping desiredID: String?
    ) async -> sending Activity<TimerActivityAttributes>? {
        // Reuse activities restored by ActivityKit after process termination.
        var matching: Activity<TimerActivityAttributes>?
        for activity in Activity<TimerActivityAttributes>.activities {
            if activity.attributes.timerID == desiredID,
               activity.activityState == .active || activity.activityState == .stale,
               matching == nil {
                matching = activity
            } else {
                if trackedActivityID == activity.id { trackedActivityID = nil }
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        return matching
    }

    private func hasNativeAlarm(_ timerID: String) -> Bool {
        if #available(iOS 26.0, *), let id = TimerAlarmScheduler.alarmID(for: timerID) {
            return (try? AlarmManager.shared.alarms.contains { $0.id == id }) == true
        }
        return false
    }
}

struct TimerLiveActivityModifier: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = TimerLiveActivityCoordinator()

    private var taskTitle: String? {
        model.canonicalTimer.flatMap { model.task(forTimerID: $0.id)?.title }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.canonicalTimer, initial: true) { synchronize() }
            .onChange(of: taskTitle) { synchronize() }
            .onChange(of: scenePhase) { synchronize() }
            .task {
                if #available(iOS 26.0, *) {
                    for await _ in AlarmManager.shared.alarmUpdates {
                        guard !Task.isCancelled else { return }
                        synchronize()
                    }
                }
            }
    }

    private func synchronize() {
        coordinator.synchronize(
            timer: model.canonicalTimer,
            taskTitle: taskTitle,
            canStart: scenePhase == .active
        )
    }
}
#endif
