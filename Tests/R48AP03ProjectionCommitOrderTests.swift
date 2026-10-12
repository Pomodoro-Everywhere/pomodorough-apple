import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP03 projection commit ordering")
struct R48AP03ProjectionCommitOrderTests {
    @Test @MainActor
    func startWithFailingStorePreservesAlertAndEmitsNoEffects() async throws {
        let suite = "PomodoroughTests.R48AP03.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let store = AtomicDurableFileStore(fileURL: storeURL)
        var seed = PersistedTimerState.fresh()
        let running = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-ap03-old")
        seed.canonicalTimer = running
        seed.localTimerOwners[running.id] = seed.deviceId
        defaults.set(try JSONEncoder.api.encode(seed), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            defaults: defaults,
            durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: scheduler
        )
        try #require(model.snapshotLoadFailure == nil)
        model.completeIfNeeded(timerID: running.id, at: running.anchorAt.addingTimeInterval(60))
        await model.waitForAlarmOperations()
        try #require(model.hasActiveCompletionAlert)
        let alertID = try #require(model.completionAlertTimerID)
        let completed = try #require(model.canonicalTimer)
        try #require(completed.status == .completed)
        let historyCount = model.history.count
        let watchBefore = model.makeWatchSnapshot()
        let durableBefore = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        scheduler.operations.removeAll()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        model.start()
        await model.waitForAlarmOperations()
        #expect(model.hasActiveCompletionAlert)
        #expect(model.completionAlertTimerID == alertID)
        #expect(model.canonicalTimer == completed)
        #expect(model.history.count == historyCount)
        #expect(scheduler.operations.isEmpty)
        #expect(model.makeWatchSnapshot().timerId == watchBefore.timerId)
        #expect(model.makeWatchSnapshot().status == watchBefore.status)
        #expect(try AtomicDurableFileStore(fileURL: storeURL).read() == durableBefore)
    }

    @Test @MainActor
    func syncInstallPersistsBeforePublishing() async throws {
        let suite = "PomodoroughTests.R48AP03Sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var initial = TestFixtures.syncContractState(includesPendingOperations: false)
        initial.history = []
        initial.canonicalTimer = CanonicalTimer(
            id: "alarm-correction-timer",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 10_000,
            anchorAt: Date(timeIntervalSince1970: 1_784_620_800),
            lastIntent: nil
        )
        initial.localTimerOwners["alarm-correction-timer"] = initial.deviceId
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let scenario = "sync-contract-alarm-status-bg-converge"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            roomStore: IrohRoomStore(
                fileURL: dir.appendingPathComponent("iroh-rooms.json"),
                secretStore: MemoryIrohRoomSecretStore(),
                now: { Date(timeIntervalSince1970: 1_784_620_800) }
            ),
            alarmScheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_784_620_800) },
            uptime: { 0 }
        )
        model.setSceneActive(false)
        model.setSceneActive(true)
        await model.restore()
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.canonicalTimer?.status == .paused)
        #expect(scheduler.operations.contains(.cancel(timerID: "alarm-correction-timer")))
        let stored = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: try #require(defaults.data(forKey: "timer-state-v2"))
        )
        #expect(stored.canonicalTimer?.status == .paused)
        #expect(stored.canonicalTimer?.id == model.canonicalTimer?.id)
    }
}
