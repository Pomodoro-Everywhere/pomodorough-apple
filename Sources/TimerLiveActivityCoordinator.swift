#if os(iOS)
import ActivityKit
import AlarmKit
import OSLog
import SwiftUI
import WidgetKit

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
        let (matching, endedTracked) = await takeMatchingActivity(keeping: desired?.id, trackedID: trackedActivityID)
        if endedTracked { trackedActivityID = nil }
        guard let desired else { return }
        let state = TimerActivityAttributes.ContentState(timer: desired, taskTitle: taskTitle)
        let content = ActivityContent(state: state, staleDate: state.isPaused ? nil : state.endsAt)
        guard let matching else {
            if canStart && ActivityAuthorizationInfo().areActivitiesEnabled {
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
                    Self.startFailed(error)
                }
            }
            return
        }
        let activityID = matching.id // local first: storing actor state before the await merges regions (Swift 6)
        trackedTimerID = desired.id
        if matching.content.state != state || matching.content.staleDate != content.staleDate {
            await matching.update(content)
        }
        trackedActivityID = activityID
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

    // NOTE: nonisolated on purpose — ActivityKit is fully nonisolated and Activity is
    // non-Sendable, so the returned activity must stay in a disconnected region to reach
    // nonisolated update/end. A @MainActor producer would merge it into the actor region
    // and Swift 6 rejects the transfer (Xcode 26.6 CI). Do not re-isolate.
    nonisolated private func takeMatchingActivity(
        keeping desiredID: String?,
        trackedID: String?
    ) async -> (Activity<TimerActivityAttributes>?, Bool) {
        // Reuse activities restored by ActivityKit after process termination.
        var matching: Activity<TimerActivityAttributes>?
        var endedTracked = false
        for activity in Activity<TimerActivityAttributes>.activities {
            if activity.attributes.timerID == desiredID,
               activity.activityState == .active || activity.activityState == .stale,
               matching == nil {
                matching = activity
            } else {
                if trackedID == activity.id { endedTracked = true }
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        return (matching, endedTracked)
    }

    private func hasNativeAlarm(_ timerID: String) -> Bool {
        if #available(iOS 26.0, *), let id = TimerAlarmScheduler.alarmID(for: timerID) {
            return (try? AlarmManager.shared.alarms.contains { $0.id == id }) == true
        }
        return false
    }
}

// Test seam: real start-failure body shared so the unit-test bundle drives
// the same capture logic on iOS without ActivityKit authorization.
// Silent delivery kept: timer and alarm operation continue unaffected.
// captureOnce: a denied Live Activity would otherwise spam on every sync.
extension TimerLiveActivityCoordinator {
    nonisolated static func startFailed(_ error: Error) {
        SentryCapture.captureOnce(key: "live-activity-start", error: error)
    }

    /// AP122: reports the widget extension's drained decode-failure count.
    /// The count is the whole payload — no snapshot, title, or error text.
    /// Once per launch; the magnitude of each batch is preserved in `count`.
    nonisolated static func reportWidgetDecodeFailures(_ count: Int) {
        guard count > 0 else { return }
        SentryCapture.captureOnce(key: "widget-snapshot-decode", error: WidgetSnapshotDecodeError(count: count))
    }
}

struct TimerLiveActivityModifier: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = TimerLiveActivityCoordinator()

    private var taskTitle: String? {
        // Prefer the task attached to the running focus timer; fall back to
        // the selected focus task so breaks still name it (displayTask is
        // nil for break phases by design).
        if let timer = model.canonicalTimer,
           let attached = model.displayTask(for: timer)?.title {
            return attached
        }
        return model.selectedTaskTitle()
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
        publishWidget()
        coordinator.synchronize(
            timer: model.canonicalTimer,
            taskTitle: taskTitle,
            canStart: scenePhase == .active
        )
    }

    private func publishWidget() {
        let timer = model.canonicalTimer.flatMap { timer in
            timer.status == .running || timer.status == .paused
                ? TimerActivityAttributes.ContentState(timer: timer, taskTitle: taskTitle) : nil
        }
        do {
            let data = try JSONEncoder().encode(TimerWidgetSnapshot(timer: timer))
            guard let defaults = UserDefaults(suiteName: TimerWidgetSnapshot.appGroup) else { return }
            // AP122: drain the extension-side decode-failure counter even
            // when the snapshot is unchanged, so an idle timer still reports.
            TimerLiveActivityCoordinator.reportWidgetDecodeFailures(TimerWidgetSnapshot.takeDecodeFailures(from: defaults))
            guard defaults.data(forKey: TimerWidgetSnapshot.storageKey) != data else { return }
            defaults.set(data, forKey: TimerWidgetSnapshot.storageKey)
            WidgetCenter.shared.reloadTimelines(ofKind: TimerWidgetSnapshot.kind)
        } catch {
            SentryCapture.captureOnce(key: "widget-snapshot", error: error)
        }
    }
}
#endif
