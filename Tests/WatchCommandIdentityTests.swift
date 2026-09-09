import Foundation
import Testing
@testable import Pomodorough

/// Backlog 2026-09-08 Watch fixes: commands carry timer identity, the phone
/// rejects delayed commands aimed at a previous timer, and payloads stay
/// wire-compatible with older watch/iOS apps that lack the new keys.
struct WatchCommandIdentityTests {
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
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)
        #expect(timerA.id != timerB.id)

        #expect(model.applyWatchCommand(.pause(timerId: timerA.id)) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func staleFinishDoesNotCompleteNewTimer() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timerA = try #require(model.canonicalTimer)
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(.finish(timerId: timerA.id)) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
    }

    @Test @MainActor
    func currentPauseAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timer = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(.pause(timerId: timer.id)) == true)
        #expect(model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func legacyPauseWithoutTimerIdAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        _ = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(.pause()) == true)
        #expect(model.canonicalTimer?.status == .paused)
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
