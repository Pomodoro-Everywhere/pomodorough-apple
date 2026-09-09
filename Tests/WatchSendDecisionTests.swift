import Foundation
import Testing
@testable import Pomodorough

/// AP50: stamping/deferred watch decisions as pure functions, covered in the
/// macOS/iOS bundle without a watchOS test host.
struct WatchSendDecisionTests {
    @Test
    func stampingPassesThroughNonControls() {
        let start = WatchTimerCommand.start()
        #expect(stampWatchTimerControl(start, snapshot: nil) == start)
        #expect(stampWatchTimerControl(.selectPhase("focus"), snapshot: nil)?.name == "selectPhase")
        let duration = WatchTimerCommand.setDuration(minutes: 20, forPhaseRawValue: "focus")
        #expect(stampWatchTimerControl(duration, snapshot: nil) == duration)
    }

    @Test
    func stampingRejectsNilSnapshotAndMismatch() {
        let pause = WatchTimerCommand.pause(timerId: "timer-a")
        #expect(stampWatchTimerControl(pause, snapshot: nil) == nil)
        let other = fixtureSnapshot(timerId: "timer-b")
        #expect(stampWatchTimerControl(pause, snapshot: other) == nil)
    }

    @Test
    func stampingAttachesRevisionOnMatch() {
        let snapshot = fixtureSnapshot(timerId: "timer-a")
        let revision = snapshot.timerRevision
        let stamped = stampWatchTimerControl(.pause(timerId: "timer-a"), snapshot: snapshot)
        #expect(stamped?.expectedTimerRevision == revision)
    }

    @Test
    func startIsLiveOnly() {
        let start = WatchTimerCommand.start()
        let live = planWatchCommandSend(start, snapshot: nil, isActivated: true, isReachable: true)
        #expect(live == .live(start))
        #expect(planWatchCommandSend(start, snapshot: nil, isActivated: true, isReachable: false)
            == .fail(.startRequiresConnection))
        #expect(planWatchCommandSend(start, snapshot: nil, isActivated: false, isReachable: true)
            == .fail(.notActivated))
    }

    @Test
    func deferredPauseLivesWhenReachableQueuesOtherwise() throws {
        let snapshot = fixtureSnapshot(timerId: "timer-a")
        let pause = WatchTimerCommand.pause(timerId: "timer-a")
        let expected = try #require(stampWatchTimerControl(pause, snapshot: snapshot))
        #expect(planWatchCommandSend(pause, snapshot: snapshot, isActivated: true, isReachable: true)
            == .live(expected))
        #expect(planWatchCommandSend(pause, snapshot: snapshot, isActivated: true, isReachable: false)
            == .queued(expected))
    }

    @Test
    func ungroundedControlFails() {
        let pause = WatchTimerCommand.pause(timerId: "timer-a")
        #expect(planWatchCommandSend(pause, snapshot: nil, isActivated: true, isReachable: true)
            == .fail(.ungrounded))
    }

    @Test
    func sendErrorFallsBackOrderedExceptStart() {
        #expect(planWatchCommandSendError(.start()) == .fail(.liveStartUnconfirmed))
        let pause = WatchTimerCommand.pause(timerId: "timer-a")
        #expect(planWatchCommandSendError(pause) == .queued(pause))
    }

    @Test
    func successfulPlansClearCommandError() throws {
        let snapshot = fixtureSnapshot(timerId: "timer-a")
        let pause = WatchTimerCommand.pause(timerId: "timer-a")
        let stamped = try #require(stampWatchTimerControl(pause, snapshot: snapshot))
        // Live/queued plans carry the accepted command: the watch clears
        // commandError when taking either path (see sendLive/queue/ingest).
        #expect(planWatchCommandSend(pause, snapshot: snapshot, isActivated: true, isReachable: true)
            == .live(stamped))
        #expect(planWatchCommandSend(pause, snapshot: snapshot, isActivated: true, isReachable: false)
            == .queued(stamped))
    }

    @Test
    func serialQueuePreservesArrivalOrderAcrossSuspension() async {
        let queue = WatchCommandSerialQueue()
        let order = LockedTestValue<[Int]>([])
        queue.enqueue { @MainActor in
            await Task.yield()
            var current = order.value
            current.append(1)
            order.value = current
        }
        queue.enqueue { @MainActor in
            var current = order.value
            current.append(2)
            order.value = current
        }
        await queue.flush()
        #expect(order.value == [1, 2])
    }

    private func fixtureSnapshot(timerId: String) -> WatchTimerSnapshot {
        let revision = WatchTimerRevision(
            timerId: timerId, intentId: "intent-1", phase: "focus",
            status: "running", plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0, anchorAt: TestFixtures.anchor
        )
        return WatchTimerSnapshot(
            phase: "focus", status: "running", timerId: timerId,
            timerRevision: revision,
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            selectedPhase: "focus",
            focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
            longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
        )
    }
}
