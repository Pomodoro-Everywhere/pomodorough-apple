import Foundation
import Testing

/// MAC-01: the Timer menu offers what the Timer screen offers, and each item
/// calls the matching timer operation.
struct TimerMenuEntryTests {
    private func enabled(_ state: TimerMenuState) -> [TimerMenuAction] {
        TimerMenuCatalog.entries(for: state).filter(\.isEnabled).map(\.action)
    }

    @Test func idleOffersStartAndSkip() {
        let state = TimerMenuState(status: .idle, hasCompletionAlert: false, acceptsCommands: true)
        #expect(TimerMenuCatalog.entries(for: state).map(\.action) == [.start, .finish, .cancel, .skip, .stopSound])
        #expect(enabled(state) == [.start, .skip])
    }

    @Test func runningOffersPauseFinishAndCancel() {
        let state = TimerMenuState(status: .running, hasCompletionAlert: false, acceptsCommands: true)
        #expect(enabled(state) == [.pause, .finish, .cancel])
    }

    @Test func pausedOffersResumeFinishAndCancel() {
        let state = TimerMenuState(status: .paused, hasCompletionAlert: false, acceptsCommands: true)
        #expect(enabled(state) == [.resume, .finish, .cancel])
    }

    @Test func completionAlertOffersStopSoundInsteadOfSkip() {
        let state = TimerMenuState(status: .idle, hasCompletionAlert: true, acceptsCommands: true)
        #expect(enabled(state) == [.start, .stopSound])
    }

    @Test(arguments: [TimerMenuState.Status.idle, .running, .paused])
    func blockedWorkspaceDisablesEveryEntry(status: TimerMenuState.Status) {
        let state = TimerMenuState(status: status, hasCompletionAlert: true, acceptsCommands: false)
        #expect(enabled(state).isEmpty)
        #expect(TimerMenuCatalog.entries(for: state).count == 5)
    }
}

@MainActor
struct TimerMenuPerformTests {
    @Test func everyActionCallsItsTimerOperation() {
        let expected: [(TimerMenuAction, RecordingTimerTarget.Call)] = [
            (.start, .start), (.pause, .pause), (.resume, .resume), (.finish, .finish),
            (.cancel, .cancel), (.skip, .skip), (.stopSound, .stopSound),
        ]
        #expect(expected.count == TimerMenuAction.allCases.count)
        for (action, call) in expected {
            let target = RecordingTimerTarget()
            TimerMenuCatalog.perform(action, on: target)
            #expect(target.calls == [call], "\(action)")
        }
    }

    @Test func menuActionsUseTheCurrentTime() {
        let target = RecordingTimerTarget()
        for action in [TimerMenuAction.pause, .resume, .finish, .cancel] {
            TimerMenuCatalog.perform(action, on: target)
        }
        #expect(target.explicitDates == [nil, nil, nil, nil])
    }
}

@MainActor
private final class RecordingTimerTarget: TimerMenuTarget {
    enum Call: Equatable {
        case start, pause, resume, finish, cancel, skip, stopSound
    }

    private(set) var calls: [Call] = []
    private(set) var explicitDates: [Date?] = []

    func start() -> Bool { record(.start, nil) }
    func pause(at explicitDate: Date?) -> Bool { record(.pause, explicitDate) }
    func resume(at explicitDate: Date?) -> Bool { record(.resume, explicitDate) }
    func finish(at explicitDate: Date?) -> Bool { record(.finish, explicitDate) }
    func cancel(at explicitDate: Date?) { record(.cancel, explicitDate) }
    func skipSelectedPhase() -> Bool { record(.skip, nil) }
    func stopSound() { record(.stopSound, nil) }

    @discardableResult
    private func record(_ call: Call, _ date: Date?) -> Bool {
        calls.append(call)
        if call != .start, call != .skip, call != .stopSound { explicitDates.append(date) }
        return true
    }
}
