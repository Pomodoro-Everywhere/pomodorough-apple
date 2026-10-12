import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP06 watch pause refusal")
struct R48AP06WatchPauseRefusalTests {
    @Test @MainActor
    func blockedMutationPauseRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let env = try seedBlockedRunning()
        defer { env.cleanup() }
        let beforeTimer = try #require(env.model.canonicalTimer)
        let beforeSnap = env.model.makeWatchSnapshot()
        let beforeRev = try #require(beforeSnap.timerRevision)
        let cmd = WatchTimerCommand(
            timerId: beforeTimer.id,
            expectedTimerRevision: beforeRev,
            name: "pause", sentAt: .now
        )
        #expect(env.model.applyWatchCommand(cmd) == false)
        #expect(env.model.canonicalTimer?.id == beforeTimer.id)
        #expect(env.model.canonicalTimer?.status == .running)
        let after = env.model.makeWatchSnapshot()
        #expect(after.status == "running")
        #expect(after.timerRevision == beforeRev)
        #expect(recorded.value.contains("pause"))
        #expect(!recorded.value.contains(beforeTimer.id))
        #expect(!(env.model.errorMessage ?? "").contains(beforeTimer.id))
    }

    @Test @MainActor
    func frozenWorkPauseRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let env = try seedFrozenRunning()
        defer { env.cleanup() }
        let timer = try #require(env.model.canonicalTimer)
        #expect(timer.status == .running)
        let rev = try #require(env.model.makeWatchSnapshot().timerRevision)
        let cmd = WatchTimerCommand(
            timerId: timer.id,
            expectedTimerRevision: rev,
            name: "pause", sentAt: .now
        )
        #expect(env.model.applyWatchCommand(cmd) == false)
        #expect(env.model.canonicalTimer?.status == .running)
        #expect(env.model.makeWatchSnapshot().status == "running")
        #expect(env.model.makeWatchSnapshot().timerRevision == rev)
        #expect(recorded.value.contains("pause"))
        #expect(!recorded.value.contains(timer.id))
    }

    @Test @MainActor
    func failedPersistencePauseRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let env = try makeFileStoreEnv()
        defer { env.cleanup() }
        env.model.start()
        let timer = try #require(env.model.canonicalTimer)
        let rev = try #require(env.model.makeWatchSnapshot().timerRevision)
        let durableBefore = try #require(try env.readDurable())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.dir.path) }
        let cmd = WatchTimerCommand(
            timerId: timer.id,
            expectedTimerRevision: rev,
            name: "pause", sentAt: .now
        )
        #expect(env.model.applyWatchCommand(cmd) == false)
        #expect(env.model.makeWatchSnapshot().status == "running")
        #expect(try env.readDurable() == durableBefore)
        #expect(recorded.value.contains("pause"))
        #expect(!recorded.value.contains(timer.id))
    }

    @Test @MainActor
    func currentPauseSucceedsAsControl() throws {
        SentryCapture.setTestBackend { _ in }
        defer { SentryCapture.resetForTesting() }
        let suite = "PomodoroughTests.R48AP06.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)
        let rev = try #require(model.makeWatchSnapshot().timerRevision)
        let cmd = WatchTimerCommand(timerId: timer.id, expectedTimerRevision: rev, name: "pause", sentAt: .now)
        #expect(model.applyWatchCommand(cmd) == true)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(model.makeWatchSnapshot().status == "paused")
    }

    @MainActor
    private func seedBlockedRunning() throws -> (model: AppModel, cleanup: () -> Void) {
        let suite = "PomodoroughTests.R48AP06.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var seed = PersistedTimerState.fresh()
        let running = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-ap06-blocked")
        seed.canonicalTimer = running
        seed.localTimerOwners[running.id] = seed.deviceId
        seed.pendingAccountSwitchUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(seed), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        try #require(model.isWorkspaceMutationBlocked)
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private func seedFrozenRunning() throws -> (model: AppModel, cleanup: () -> Void) {
        let suite = "PomodoroughTests.R48AP06.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var seed = PersistedTimerState.fresh()
        let running = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-ap06-frozen")
        seed.canonicalTimer = running
        seed.localTimerOwners[running.id] = seed.deviceId
        defaults.set(try JSONEncoder.api.encode(seed), forKey: "timer-state-v2")
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.core("frozen work") }
        )
        try #require(model.canonicalTimer?.status == .running)
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private func makeFileStoreEnv() throws -> (
        model: AppModel, dir: URL, readDurable: () throws -> Data?, cleanup: () -> Void
    ) {
        let suite = "PomodoroughTests.R48AP06.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("workspace.json")
        let store = AtomicDurableFileStore(fileURL: storeURL)
        let model = AppModel(
            defaults: defaults,
            durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler()
        )
        let read: () throws -> Data? = {
            try AtomicDurableFileStore(fileURL: storeURL).read()
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        return (model, dir, read, cleanup)
    }
}
