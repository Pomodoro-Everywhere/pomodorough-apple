#if os(iOS)
import Foundation

/// What may let the coordinator request a new timer Live Activity.
struct TimerLiveActivityStartConditions: Equatable, Sendable {
    /// ActivityKit accepts a new request only from an active scene.
    let isSceneActive: Bool
    /// The person used a timer control in this process (`AppModel.timerControlUsedInProcess`).
    let timerControlUsedInProcess: Bool
}

/// What the coordinator does with the timer's Live Activity on one reconcile.
enum TimerLiveActivityStep: Equatable, Sendable {
    /// No activity presents the timer and none is requested.
    case noActivity
    /// Request a new activity, subject to the system authorization check.
    case start
    /// Update the activity that already presents the timer.
    case update
}

/// Client presentation policy for the timer's Live Activity. It decides only
/// whether an activity is shown; the timer itself stays a Core decision.
enum TimerLiveActivityPolicy {
    /// The timer a Live Activity may present, or nil when none may exist.
    /// A dismissed timer stays nil, so its activity is never requested again.
    static func presentedTimer(
        _ timer: CanonicalTimer?,
        now: Date,
        dismissedTimerID: String?,
        hasNativeAlarm: (String) -> Bool
    ) -> CanonicalTimer? {
        guard let timer else { return nil }
        let active = timer.status == .running || timer.status == .paused
        if !active || timer.remaining(at: now) <= 0
            || hasNativeAlarm(timer.id) || dismissedTimerID == timer.id {
            return nil
        }
        return timer
    }

    /// IOS27-23: an existing activity is always kept up to date. A new one is
    /// requested for a running timer, and for a paused timer only after the
    /// person used a timer control in this process. Opening the app to look
    /// at a paused timer therefore adds nothing to the Lock Screen.
    static func step(
        for timer: CanonicalTimer,
        matchingActivityExists: Bool,
        conditions: TimerLiveActivityStartConditions
    ) -> TimerLiveActivityStep {
        if matchingActivityExists { return .update }
        guard conditions.isSceneActive else { return .noActivity }
        if timer.status == .running || conditions.timerControlUsedInProcess { return .start }
        return .noActivity
    }
}
#endif
