import Foundation
import Testing
#if os(iOS)
import WatchConnectivity
#endif
@testable import Pomodorough

/// Backlog 2026-09-08 Watch fixes: commands carry timer identity, the phone
/// rejects delayed commands aimed at a previous timer or timer revision.
struct WatchCommandIdentityTests {
#if os(iOS)
    @Test @MainActor
    func liveRefreshDelegateReturnsPublishedSnapshot() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        var reply: [String: Any] = [:]
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let runningData = try #require(reply[WatchSyncKeys.snapshot] as? Data)
        let running = try JSONDecoder().decode(WatchTimerSnapshot.self, from: runningData)
        #expect(running.isRunning)
        #expect(running.timerRevision == model.makeWatchSnapshot().timerRevision)
        model.pause()
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let pausedData = try #require(reply[WatchSyncKeys.snapshot] as? Data)
        let paused = try JSONDecoder().decode(WatchTimerSnapshot.self, from: pausedData)
        #expect(paused.isPaused)
        #expect(paused.timerRevision == model.makeWatchSnapshot().timerRevision)
    }
#endif
    @Test @MainActor
    func deferredStartCannotRunAfterNewerPhoneActivityOrReplay() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = WatchTimerCommand.start()
        #expect(!start.allowsDeferredDelivery)
        #expect(model.applyWatchCommand(start))
        model.finish()
        let finished = model.canonicalTimer
        #expect(!model.applyWatchCommand(start, isDeferred: true))
        #expect(model.canonicalTimer == finished)
        #expect(!model.applyWatchCommand(.start(), isDeferred: true))
        #expect(model.canonicalTimer == finished)
        #expect(WatchTimerCommand.pause(timerId: "timer").allowsDeferredDelivery)
    }

    @Test @MainActor
    func refreshReplyContainsDecodableCurrentSnapshot() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let snapshot = model.makeWatchSnapshot()
        let reply = WatchSyncService.snapshotReply(try JSONEncoder().encode(snapshot))
        let data = try #require(reply[WatchSyncKeys.snapshot])
        #expect(try JSONDecoder().decode(WatchTimerSnapshot.self, from: data) == snapshot)
    }

    @Test
    func commandRoundTripKeepsIdentities() throws {
        let command = WatchTimerCommand.pause(timerId: "timer-a")
        let decoded = try JSONDecoder().decode(
            WatchTimerCommand.self,
            from: JSONEncoder().encode(command)
        )
        #expect(decoded == command)
        #expect(decoded.timerId == "timer-a")
    }

    @Test
    func legacyCommandWithoutIdentitiesStillDecodes() throws {
        let data = try legacyPayload(from: WatchTimerCommand.pause(timerId: "timer-a"))
        let decoded = try JSONDecoder().decode(WatchTimerCommand.self, from: data)
        #expect(decoded.name == "pause")
        #expect(decoded.timerId == nil)
    }

    @Test
    func legacySnapshotWithoutTimerIdStillDecodes() throws {
        let snapshot = WatchTimerSnapshot(
            phase: "focus", status: "running", timerId: "timer-a",
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            selectedPhase: "focus",
            focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
            longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
        )
        let data = try JSONEncoder().encode(snapshot)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        dict?.removeValue(forKey: "timerId")
        let legacy = try JSONSerialization.data(withJSONObject: dict ?? [:])
        let decoded = try JSONDecoder().decode(WatchTimerSnapshot.self, from: legacy)
        #expect(decoded.timerId == nil)
        #expect(decoded.phase == "focus")
    }

    @Test @MainActor
    func snapshotCarriesActiveTimerId() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timer = try #require(model.canonicalTimer)
        #expect(model.makeWatchSnapshot().timerId == timer.id)
    }

    @Test @MainActor
    func idleSnapshotHasNilTimerId() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(model.makeWatchSnapshot().timerId == nil)
    }

    @Test @MainActor
    func stalePauseForPreviousTimerRejected() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timerA = try #require(model.canonicalTimer)
        let revisionA = try #require(model.makeWatchSnapshot().timerRevision)
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)
        #expect(timerA.id != timerB.id)

        #expect(model.applyWatchCommand(WatchTimerCommand(
            timerId: timerA.id, expectedTimerRevision: revisionA,
            name: "pause", sentAt: .now
        )) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func staleFinishDoesNotCompleteNewTimer() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timerA = try #require(model.canonicalTimer)
        let revisionA = try #require(model.makeWatchSnapshot().timerRevision)
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(WatchTimerCommand(
            timerId: timerA.id, expectedTimerRevision: revisionA,
            name: "finish", sentAt: .now
        )) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
    }

    @Test @MainActor
    func currentPauseAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timer = try #require(model.canonicalTimer)

        let command = WatchTimerCommand(
            timerId: timer.id,
            expectedTimerRevision: model.makeWatchSnapshot().timerRevision,
            name: "pause", sentAt: .now
        )
        let decoded = try JSONDecoder().decode(
            WatchTimerCommand.self, from: JSONEncoder().encode(command)
        )
        #expect(decoded == command)
        #expect(model.applyWatchCommand(decoded) == true)
        #expect(model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func legacyPauseWithoutRevisionRejected() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        _ = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(.pause()) == false)
        #expect(model.applyWatchCommand(.pause(timerId: model.canonicalTimer?.id)) == false)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func queuedPauseCannotOverrideNewerPhoneResume() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let revision = try #require(model.makeWatchSnapshot().timerRevision)
        let queued = WatchTimerCommand(
            timerId: revision.timerId, expectedTimerRevision: revision,
            name: "pause", sentAt: .distantFuture
        )
        model.pause()
        model.resume()
        let current = model.canonicalTimer
        #expect(model.applyWatchCommand(queued) == false)
        #expect(model.canonicalTimer == current)
    }

    @Test @MainActor
    func liveResumeWinsOverOlderQueuedPauseAndReplay() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let initial = try #require(model.makeWatchSnapshot().timerRevision)
        let pause = WatchTimerCommand(
            timerId: initial.timerId, expectedTimerRevision: initial,
            name: "pause", sentAt: .distantPast
        )
        #expect(model.applyWatchCommand(pause))
        #expect(!model.applyWatchCommand(pause))
        let paused = try #require(model.makeWatchSnapshot().timerRevision)
        let resume = WatchTimerCommand(
            timerId: paused.timerId, expectedTimerRevision: paused,
            name: "resume", sentAt: .distantPast
        )
        #expect(model.applyWatchCommand(resume))
        #expect(!model.applyWatchCommand(pause))
        #expect(!model.applyWatchCommand(resume))
        #expect(model.canonicalTimer?.status == .running)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.applyWatchCommand(pause))
        #expect(!restored.applyWatchCommand(resume))
        #expect(restored.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func staleFinishRejectedAndFreshFinishAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let initial = try #require(model.makeWatchSnapshot().timerRevision)
        var finish = WatchTimerCommand(
            timerId: initial.timerId, expectedTimerRevision: initial,
            name: "finish", sentAt: .now
        )
        model.pause()
        #expect(!model.applyWatchCommand(finish))
        finish.expectedTimerRevision = model.makeWatchSnapshot().timerRevision
        #expect(model.applyWatchCommand(finish))
        #expect(!model.applyWatchCommand(finish))
    }

    @Test @MainActor
    func settingsCommandsUnaffectedByGuard() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(model.applyWatchCommand(.selectPhase("focus")) == true)
        #expect(model.applyWatchCommand(
            .setDuration(minutes: 20, forPhaseRawValue: "focus")
        ) == true)
        #expect(model.durationMinutes(for: .focus) == 20)
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel() -> (AppModel, UserDefaults, String) {
        let suite = "PomodoroughTests.WatchIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        return (model, defaults, suite)
    }

    private func legacyPayload(from command: WatchTimerCommand) throws -> Data {
        let data = try JSONEncoder().encode(command)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        dict?.removeValue(forKey: "id")
        dict?.removeValue(forKey: "timerId")
        return try JSONSerialization.data(withJSONObject: dict ?? [:])
    }
}
