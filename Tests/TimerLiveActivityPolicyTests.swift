#if os(iOS)
import Foundation
import Testing
@testable import Pomodorough

/// IOS27-23: opening the app on a paused timer must not create a Live
/// Activity until the person uses a timer control in this process.
@Suite("IOS27-23 Live Activity start policy")
struct TimerLiveActivityPolicyTests {
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private static let noTimerControl = TimerLiveActivityStartConditions(
        isSceneActive: true, timerControlUsedInProcess: false
    )
    private static let timerControlUsed = TimerLiveActivityStartConditions(
        isSceneActive: true, timerControlUsedInProcess: true
    )

    @Test
    func pausedTimerWithoutTimerControlDoesNotStart() {
        let step = TimerLiveActivityPolicy.step(
            for: Self.timer(.paused), matchingActivityExists: false, conditions: Self.noTimerControl
        )
        #expect(step == .noActivity)
    }

    @Test
    func pausedTimerAfterTimerControlStarts() {
        let step = TimerLiveActivityPolicy.step(
            for: Self.timer(.paused), matchingActivityExists: false, conditions: Self.timerControlUsed
        )
        #expect(step == .start)
    }

    @Test
    func runningTimerStartsWithoutTimerControl() {
        let step = TimerLiveActivityPolicy.step(
            for: Self.timer(.running), matchingActivityExists: false, conditions: Self.noTimerControl
        )
        #expect(step == .start)
    }

    @Test(arguments: [CanonicalTimer.Status.paused, .running], [true, false])
    func matchingActivityIsUpdatedWithoutTimerControl(status: CanonicalTimer.Status, isSceneActive: Bool) {
        let step = TimerLiveActivityPolicy.step(
            for: Self.timer(status),
            matchingActivityExists: true,
            conditions: TimerLiveActivityStartConditions(
                isSceneActive: isSceneActive, timerControlUsedInProcess: false
            )
        )
        #expect(step == .update)
    }

    @Test(arguments: [CanonicalTimer.Status.paused, .running])
    func inactiveSceneDoesNotStart(status: CanonicalTimer.Status) {
        let step = TimerLiveActivityPolicy.step(
            for: Self.timer(status),
            matchingActivityExists: false,
            conditions: TimerLiveActivityStartConditions(
                isSceneActive: false, timerControlUsedInProcess: true
            )
        )
        #expect(step == .noActivity)
    }

    @Test(arguments: [CanonicalTimer.Status.paused, .running])
    func dismissedTimerIsNotPresentedAgain(status: CanonicalTimer.Status) {
        let timer = Self.timer(status)

        #expect(Self.presented(timer, dismissedTimerID: timer.id) == nil)
        #expect(Self.presented(timer, dismissedTimerID: "timer-other") == timer)
        #expect(Self.presented(timer, dismissedTimerID: nil) == timer)
    }

    @Test
    func timerWithNativeAlarmOrWithoutRemainingTimeIsNotPresented() {
        let running = Self.timer(.running)

        let withNativeAlarm = Self.presented(running, hasNativeAlarm: { $0 == running.id })
        #expect(withNativeAlarm == nil)
        #expect(Self.presented(running, now: Self.anchor.addingTimeInterval(1_500)) == nil)
        #expect(Self.presented(Self.timer(.completed)) == nil)
        #expect(Self.presented(Self.timer(.cancelled)) == nil)
        #expect(Self.presented(nil) == nil)
    }

    /// The signal a relaunched model reports feeds the policy the way
    /// `TimerLiveActivityModifier` feeds it.
    @Test @MainActor
    func relaunchOnPausedTimerRequestsNoActivityUntilTimerControlIsUsed() throws {
        let fixture = try TimerControlFixture(seededTimerStatus: .paused)
        defer { fixture.cleanUp() }
        let model = fixture.model

        let paused = try #require(model.canonicalTimer)
        #expect(Self.stepAfterLaunch(model, timer: paused) == .noActivity)

        try #require(model.resume())
        try #require(model.pause())

        let pausedAgain = try #require(model.canonicalTimer)
        try #require(pausedAgain.status == .paused)
        #expect(Self.stepAfterLaunch(model, timer: pausedAgain) == .start)
    }

    @MainActor
    private static func stepAfterLaunch(_ model: AppModel, timer: CanonicalTimer) -> TimerLiveActivityStep {
        TimerLiveActivityPolicy.step(
            for: timer,
            matchingActivityExists: false,
            conditions: TimerLiveActivityStartConditions(
                isSceneActive: true, timerControlUsedInProcess: model.timerControlUsedInProcess
            )
        )
    }

    private static func presented(
        _ timer: CanonicalTimer?,
        now: Date = anchor,
        dismissedTimerID: String? = nil,
        hasNativeAlarm: (String) -> Bool = { _ in false }
    ) -> CanonicalTimer? {
        TimerLiveActivityPolicy.presentedTimer(
            timer, now: now, dismissedTimerID: dismissedTimerID, hasNativeAlarm: hasNativeAlarm
        )
    }

    private static func timer(_ status: CanonicalTimer.Status) -> CanonicalTimer {
        CanonicalTimer(
            id: "timer-live-activity", taskId: nil, phase: .focus, status: status,
            plannedDurationMs: 1_500_000, elapsedAtAnchorMs: 600_000,
            anchorAt: anchor, lastIntent: nil
        )
    }
}
#endif
