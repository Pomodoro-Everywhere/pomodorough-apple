import Foundation
import Testing
@testable import Pomodorough

@Suite("Background stale alarm")
struct BackgroundStaleAlarmTests {
    @Test @MainActor
    func backgroundedRemotePauseConvergesWithoutFinish() async throws {
        let fixture = try StaleAlarmFixture(scenario: "sync-contract-alarm-status-bg-converge")
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let scheduler = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarmScheduler: scheduler)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        await model.restore()
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(scheduler.operations.contains(.cancel(timerID: "alarm-correction-timer")))
        #expect(!scheduler.operations.contains(where: { if case .schedule = $0 { return true }; return false }) || model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func wakeOrderingPauseWinsOverStaleFinish() async throws {
        let fixture = try StaleAlarmFixture(scenario: "sync-contract-alarm-status-bg-order")
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let model = fixture.makeModel(alarmScheduler: RecordingAlarmScheduler())
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        #expect(model.completedFocusCount == 0)
        await model.restore()
        await model.refreshAfterForeground()
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func manualFinishRequiresPostSyncProjection() async throws {
        let fixture = try StaleAlarmFixture(scenario: "sync-contract-alarm-status-bg-manual")
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let model = fixture.makeModel(alarmScheduler: RecordingAlarmScheduler())
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.finish()
        #expect(model.completedFocusCount == 0)
        #expect(model.errorMessage != nil)
        await model.restore()
        await model.refreshAfterForeground()
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .paused)
        model.errorMessage = nil
        model.finish(at: fixture.clock.now)
        #expect(model.completedFocusCount == 1)
    }

    @Test @MainActor
    func alarmFireThenOpenDropsStaleFinish() async throws {
        let fixture = try StaleAlarmFixture(scenario: "sync-contract-alarm-status-bg-fire")
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let model = fixture.makeModel(alarmScheduler: RecordingAlarmScheduler())
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.completeIfNeeded(timerID: "alarm-correction-timer", at: fixture.clock.now)
        #expect(model.completedFocusCount == 0)
        model.setSceneActive(true)
        #expect(model.completedFocusCount == 0)
        await model.restore()
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func missedPauseResumeTwinKeepsRunning() async throws {
        let fixture = try StaleAlarmFixture(scenario: "sync-contract-alarm-elapsed-bg-twin")
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let scheduler = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarmScheduler: scheduler)
        model.setSceneActive(false)
        fixture.clock.elapsed = 30
        model.setSceneActive(true)
        #expect(model.completedFocusCount == 0)
        await model.restore()
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        #expect(scheduler.operations.contains(.cancel(timerID: "alarm-correction-timer")))
    }
}

@MainActor
private final class StaleAlarmClock {
    let anchor = Date(timeIntervalSince1970: 1_784_620_800)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

@MainActor
private final class StaleSleepGate {
    private var continuations: [CheckedContinuation<Void, any Error>?] = []
    private(set) var count = 0
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            count += 1
            continuations.append(continuation)
        }
    }
    func releaseAll() {
        for index in continuations.indices {
            continuations[index]?.resume()
            continuations[index] = nil
        }
    }
}

@MainActor
private struct StaleAlarmFixture {
    let scenario: String
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let clock = StaleAlarmClock()
    let sleeper = StaleSleepGate()
    let roomStore: IrohRoomStore

    init(scenario: String) throws {
        self.scenario = scenario
        suiteName = "PomodoroughTests.StaleAlarm.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let clock = clock
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"),
            secretStore: MemoryIrohRoomSecretStore(),
            now: { clock.now }
        )
    }

    func seedRunningTimer() throws {
        var initial = TestFixtures.syncContractState(includesPendingOperations: false)
        initial.canonicalTimer = CanonicalTimer(
            id: "alarm-correction-timer",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 10_000,
            anchorAt: clock.anchor,
            lastIntent: nil
        )
        initial.localTimerOwners["alarm-correction-timer"] = initial.deviceId
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
    }

    func makeModel(alarmScheduler: RecordingAlarmScheduler) -> AppModel {
        let clock = clock
        let sleeper = sleeper
        let session = TestFixtures.session(for: scenario)
        return AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            roomStore: roomStore,
            alarmScheduler: alarmScheduler,
            completionScheduler: TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) }),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { clock.now },
            uptime: { clock.elapsed }
        )
    }

    func cleanUp() {
        sleeper.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
