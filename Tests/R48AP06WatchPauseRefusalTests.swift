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

@Suite("R49-AP04 watch start/resume/finish refusal")
struct R49AP04WatchStartResumeFinishRefusalTests {
    @Test @MainActor
    func blockedStartResumeFinishRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let idle = try seedBlocked(status: nil, timerID: "timer-ap04-blocked-start")
        defer { idle.1() }
        #expect(idle.0.applyWatchCommand(.start()) == false)
        #expect(idle.0.canonicalTimer == nil)
        let paused = try seedBlocked(status: .paused, timerID: "timer-ap04-blocked-resume")
        defer { paused.1() }
        let resume = try currentCommand(name: "resume", model: paused.0)
        #expect(paused.0.applyWatchCommand(resume) == false)
        #expect(paused.0.canonicalTimer?.status == .paused)
        let running = try seedBlocked(status: .running, timerID: "timer-ap04-blocked-finish")
        defer { running.1() }
        let finish = try currentCommand(name: "finish", model: running.0)
        #expect(running.0.applyWatchCommand(finish) == false)
        #expect(running.0.canonicalTimer?.status == .running)
        #expect(recorded.value.contains("start"))
        #expect(recorded.value.contains("resume"))
        #expect(recorded.value.contains("finish"))
        #expect(!recorded.value.contains("timer-ap04-blocked-start"))
        #expect(!recorded.value.contains("timer-ap04-blocked-resume"))
        #expect(!recorded.value.contains("timer-ap04-blocked-finish"))
    }

    @Test @MainActor
    func frozenStartResumeFinishRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let idle = try seedFrozen(status: nil, timerID: "timer-ap04-frozen-start")
        defer { idle.1() }
        #expect(idle.0.applyWatchCommand(.start()) == false)
        #expect(idle.0.canonicalTimer == nil)
        let paused = try seedFrozen(status: .paused, timerID: "timer-ap04-frozen-resume")
        defer { paused.1() }
        let resume = try currentCommand(name: "resume", model: paused.0)
        #expect(paused.0.applyWatchCommand(resume) == false)
        #expect(paused.0.canonicalTimer?.status == .paused)
        let running = try seedFrozen(status: .running, timerID: "timer-ap04-frozen-finish")
        defer { running.1() }
        let finish = try currentCommand(name: "finish", model: running.0)
        #expect(running.0.applyWatchCommand(finish) == false)
        #expect(running.0.canonicalTimer?.status == .running)
        #expect(recorded.value.contains("start"))
        #expect(recorded.value.contains("resume"))
        #expect(recorded.value.contains("finish"))
        #expect(!recorded.value.contains("timer-ap04-frozen-start"))
        #expect(!recorded.value.contains("timer-ap04-frozen-resume"))
        #expect(!recorded.value.contains("timer-ap04-frozen-finish"))
    }

    @Test @MainActor
    func failedWriteStartRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let env = try makeFileStoreEnv()
        defer { env.cleanup() }
        let beforeStatus = env.model.makeWatchSnapshot().status
        let durableBefore = try env.readDurable()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.dir.path) }
        #expect(env.model.applyWatchCommand(.start()) == false)
        #expect(env.model.canonicalTimer == nil)
        #expect(env.model.makeWatchSnapshot().status == beforeStatus)
        #expect(try env.readDurable() == durableBefore)
        #expect(recorded.value.contains("start"))
    }

    @Test @MainActor
    func failedWriteResumeRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let env = try makeFileStoreEnv()
        defer { env.cleanup() }
        env.model.start()
        env.model.pause()
        let timer = try #require(env.model.canonicalTimer)
        let rev = try #require(env.model.makeWatchSnapshot().timerRevision)
        let durableBefore = try #require(try env.readDurable())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.dir.path) }
        let cmd = WatchTimerCommand(timerId: timer.id, expectedTimerRevision: rev, name: "resume", sentAt: .now)
        #expect(env.model.applyWatchCommand(cmd) == false)
        #expect(env.model.canonicalTimer?.status == .paused)
        #expect(env.model.makeWatchSnapshot().timerRevision == rev)
        #expect(try env.readDurable() == durableBefore)
        #expect(recorded.value.contains("resume"))
        #expect(!recorded.value.contains(timer.id))
    }

    @Test @MainActor
    func failedWriteFinishRefused() throws {
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
        let cmd = WatchTimerCommand(timerId: timer.id, expectedTimerRevision: rev, name: "finish", sentAt: .now)
        #expect(env.model.applyWatchCommand(cmd) == false)
        #expect(env.model.canonicalTimer?.status == .running)
        #expect(env.model.makeWatchSnapshot().timerRevision == rev)
        #expect(try env.readDurable() == durableBefore)
        #expect(recorded.value.contains("finish"))
        #expect(!recorded.value.contains(timer.id))
    }

    @Test @MainActor
    func staleResumeFinishAndDeferredStartRefusedWithoutDiagnostic() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let pausedSuite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let pausedDefaults = try #require(UserDefaults(suiteName: pausedSuite))
        defer { pausedDefaults.removePersistentDomain(forName: pausedSuite) }
        let pausedModel = AppModel(defaults: pausedDefaults, alarmScheduler: RecordingAlarmScheduler())
        pausedModel.start()
        pausedModel.pause()
        let pausedRev = try #require(pausedModel.makeWatchSnapshot().timerRevision)
        let staleResume = WatchTimerCommand(timerId: "stale-timer", expectedTimerRevision: pausedRev, name: "resume", sentAt: .now)
        #expect(pausedModel.applyWatchCommand(staleResume) == false)
        #expect(pausedModel.canonicalTimer?.status == .paused)
        let runningSuite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let runningDefaults = try #require(UserDefaults(suiteName: runningSuite))
        defer { runningDefaults.removePersistentDomain(forName: runningSuite) }
        let runningModel = AppModel(defaults: runningDefaults, alarmScheduler: RecordingAlarmScheduler())
        runningModel.start()
        let runningRev = try #require(runningModel.makeWatchSnapshot().timerRevision)
        let staleFinish = WatchTimerCommand(timerId: "stale-timer", expectedTimerRevision: runningRev, name: "finish", sentAt: .now)
        #expect(runningModel.applyWatchCommand(staleFinish) == false)
        #expect(runningModel.canonicalTimer?.status == .running)
        #expect(pausedModel.applyWatchCommand(.start(), isDeferred: true) == false)
        #expect(recorded.value.isEmpty)
        #expect(pausedModel.errorMessage == nil)
        #expect(runningModel.errorMessage == nil)
    }

    @Test @MainActor
    func replaySecondStartResumeFinishRefused() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let suite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(model.applyWatchCommand(.start()) == true)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.applyWatchCommand(.start()) == false)
        #expect(model.canonicalTimer?.status == .running)
        let pause = try currentCommand(name: "pause", model: model)
        #expect(model.applyWatchCommand(pause) == true)
        let resume = try currentCommand(name: "resume", model: model)
        #expect(model.applyWatchCommand(resume) == true)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.applyWatchCommand(resume) == false)
        #expect(model.canonicalTimer?.status == .running)
        let finish = try currentCommand(name: "finish", model: model)
        #expect(model.applyWatchCommand(finish) == true)
        #expect(model.applyWatchCommand(finish) == false)
        #expect(recorded.value.contains("start"))
    }

    @Test @MainActor
    func successStartResumeFinishAccepted() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let suite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(model.applyWatchCommand(.start()) == true)
        #expect(model.canonicalTimer?.status == .running)
        let pause = try currentCommand(name: "pause", model: model)
        #expect(model.applyWatchCommand(pause) == true)
        #expect(model.canonicalTimer?.status == .paused)
        let resume = try currentCommand(name: "resume", model: model)
        #expect(model.applyWatchCommand(resume) == true)
        #expect(model.canonicalTimer?.status == .running)
        let finish = try currentCommand(name: "finish", model: model)
        #expect(model.applyWatchCommand(finish) == true)
        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.makeWatchSnapshot().status == "idle")
        #expect(recorded.value.isEmpty)
    }

    @MainActor
    private func seedBlocked(status: CanonicalTimer.Status?, timerID: String) throws -> (AppModel, () -> Void) {
        let suite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var seed = PersistedTimerState.fresh()
        if let status {
            let timer = TestFixtures.timer(status: status, elapsed: 0, timerID: timerID)
            seed.canonicalTimer = timer
            seed.localTimerOwners[timer.id] = seed.deviceId
        }
        seed.pendingAccountSwitchUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(seed), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        try #require(model.isWorkspaceMutationBlocked)
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private func seedFrozen(status: CanonicalTimer.Status?, timerID: String) throws -> (AppModel, () -> Void) {
        let suite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var seed = PersistedTimerState.fresh()
        if let status {
            let timer = TestFixtures.timer(status: status, elapsed: 0, timerID: timerID)
            seed.canonicalTimer = timer
            seed.localTimerOwners[timer.id] = seed.deviceId
        }
        defaults.set(try JSONEncoder.api.encode(seed), forKey: "timer-state-v2")
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.core("frozen work") }
        )
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private func makeFileStoreEnv() throws -> (
        model: AppModel, dir: URL, readDurable: () throws -> Data?, cleanup: () -> Void
    ) {
        let suite = "PomodoroughTests.R49AP04.\(UUID().uuidString)"
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

    @MainActor
    private func currentCommand(name: String, model: AppModel) throws -> WatchTimerCommand {
        let timer = try #require(model.canonicalTimer)
        let rev = try #require(model.makeWatchSnapshot().timerRevision)
        return WatchTimerCommand(timerId: timer.id, expectedTimerRevision: rev, name: name, sentAt: .now)
    }
}
