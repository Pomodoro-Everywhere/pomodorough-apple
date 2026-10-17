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

@Suite("R49-AP03 local phase commit ordering")
struct R49AP03LocalPhaseCommitTests {
    @Test @MainActor
    func idleFirstWriteDenialKeepsPreviousPhase() async throws {
        let suite = "PomodoroughTests.R49AP03IdleDenial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        var seed = PersistedTimerState.fresh()
        seed.settings.selectedPhase = .focus
        let seedBytes = try JSONEncoder.api.encode(seed)
        try AtomicDurableFileStore(fileURL: storeURL).write(seedBytes)
        defaults.set(seedBytes, forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: scheduler)
        try #require(model.snapshotLoadFailure == nil)
        try #require(model.selectedPhase == .focus)
        let durableBefore = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        let mirrorBefore = try #require(defaults.data(forKey: "timer-state-v2"))
        let watchBefore = model.makeWatchSnapshot()
        scheduler.operations.removeAll()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        model.selectPhase(.longBreak)
        let durableAfter = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        let mirrorAfter = try #require(defaults.data(forKey: "timer-state-v2"))
        #expect(durableAfter == durableBefore)
        #expect(mirrorAfter == mirrorBefore)
        #expect(model.selectedPhase == .focus)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: durableAfter).selectedPhaseGeneration == 0)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: durableAfter).hasExplicitPhaseSelection == false)
        #expect(scheduler.operations.isEmpty)
        #expect(model.makeWatchSnapshot().selectedPhase == watchBefore.selectedPhase)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        model.selectPhase(.longBreak)
        #expect(model.selectedPhase == .longBreak)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: try #require(try AtomicDurableFileStore(fileURL: storeURL).read())).selectedPhaseGeneration == 1)
    }

    @Test @MainActor
    func idleDeniedPhaseDoesNotControlNextStartOrReopen() async throws {
        let suite = "PomodoroughTests.R49AP03IdleStart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let seedBytes = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        try AtomicDurableFileStore(fileURL: storeURL).write(seedBytes)
        defaults.set(seedBytes, forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        model.selectPhase(.longBreak)
        #expect(model.selectedPhase == .focus)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        model.start()
        await model.waitForAlarmOperations()
        let started = try #require(model.canonicalTimer)
        #expect(started.phase == .focus)
        #expect(model.selectedPhase == .focus)
        let reopened = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        #expect(reopened.selectedPhase == .focus)
        #expect(reopened.canonicalTimer?.phase == .focus)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: try #require(try AtomicDurableFileStore(fileURL: storeURL).read())).settings.selectedPhase == .focus)
    }

    @Test @MainActor
    func activeFirstWriteDenialKeepsRunningFocus() async throws {
        let suite = "PomodoroughTests.R49AP03ActiveDenial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let seedBytes = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        try AtomicDurableFileStore(fileURL: storeURL).write(seedBytes)
        defaults.set(seedBytes, forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: scheduler)
        model.start()
        await model.waitForAlarmOperations()
        let running = try #require(model.canonicalTimer)
        try #require(running.phase == .focus)
        let durableBefore = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        scheduler.operations.removeAll()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        model.selectPhase(.longBreak)
        #expect(model.canonicalTimer?.id == running.id)
        #expect(model.selectedPhase == .focus)
        #expect(try AtomicDurableFileStore(fileURL: storeURL).read() == durableBefore)
        #expect(scheduler.operations.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let reopened = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        #expect(reopened.canonicalTimer?.id == running.id)
        #expect(reopened.selectedPhase == .focus)
    }

    @Test @MainActor
    func idleReplacementUncertaintyPreservesReadback() throws {
        let suite = "PomodoroughTests.R49AP03IdleUncertain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let seedBytes = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        try AtomicDurableFileStore(fileURL: storeURL).write(seedBytes)
        defaults.set(seedBytes, forKey: "timer-state-v2")
        let store = AtomicDurableFileStore(fileURL: storeURL, afterReplacement: { throw POSIXError(.EIO) })
        let model = AppModel(defaults: defaults, durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        model.selectPhase(.longBreak)
        let durable = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        let observed = try JSONDecoder.api.decode(PersistedTimerState.self, from: durable)
        #expect(observed.settings.selectedPhase == .longBreak)
        #expect(model.selectedPhase == .longBreak)
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.conflictMessage != nil)
        #expect(defaults.data(forKey: "timer-state-v2") == seedBytes)
        let mirrorReadsOld = try JSONDecoder.api.decode(PersistedTimerState.self, from: try #require(defaults.data(forKey: "timer-state-v2")))
        #expect(mirrorReadsOld.settings.selectedPhase == .focus)
    }

    @Test @MainActor
    func activeReplacementUncertaintyAdoptsObservedReplacement() async throws {
        let suite = "PomodoroughTests.R49AP03ActiveUncertain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let seedBytes = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        try AtomicDurableFileStore(fileURL: storeURL).write(seedBytes)
        defaults.set(seedBytes, forKey: "timer-state-v2")
        let plain = AppModel(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: storeURL), roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        plain.start()
        await plain.waitForAlarmOperations()
        let running = try #require(plain.canonicalTimer)
        let store = AtomicDurableFileStore(fileURL: storeURL, afterReplacement: { throw POSIXError(.EIO) })
        let model = AppModel(defaults: defaults, durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: RecordingAlarmScheduler())
        try #require(model.canonicalTimer?.id == running.id)
        model.selectPhase(.longBreak)
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        let durable = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: durable).settings.selectedPhase == .longBreak)
    }
}
