import Foundation
import Testing
@testable import Pomodorough

@Suite("R50-AP02 bootstrap commit ordering")
struct R50AP02BootstrapCommitOrderTests {
    @MainActor
    private func emptyInitial() -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        return state
    }

    @MainActor
    private func persisted(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    @MainActor
    private func watchCount(_ defaults: UserDefaults) -> Int {
        defaults.integer(forKey: "watch-snapshot-seq-count")
    }

    @MainActor
    private func makeEnv(
        scenario: String,
        store: AtomicDurableFileStore,
        dir: URL,
        defaults: UserDefaults,
        scheduler: RecordingAlarmScheduler
    ) -> AppModel {
        AppModel(
            api: APIClient(
                session: TestFixtures.session(for: scenario),
                keychain: StaticTokenStore()
            ),
            defaults: defaults,
            durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: scheduler
        )
    }

    @Test @MainActor
    func firstWriteDenialKeepsIdleAndRetainsRequest() async throws {
        let scenario = "bootstrap-legacy-ownership-remote"
        let suite = "PomodoroughTests.R50AP02FirstWrite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let bytes = try JSONEncoder.api.encode(emptyInitial())
        try AtomicDurableFileStore(fileURL: storeURL).write(bytes)
        defaults.set(bytes, forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let writes = LockedValue(value: 0)
        let dirPath = dir.path
        let store = AtomicDurableFileStore(fileURL: storeURL, afterReplacement: {
            writes.set(writes.value + 1)
            if writes.value == 1 {
                _ = dirPath.withCString { chmod($0, 0o555) }
            }
        })
        let model = makeEnv(scenario: scenario, store: store, dir: dir, defaults: defaults, scheduler: scheduler)
        let baseline = watchCount(defaults)
        scheduler.operations.removeAll()
        await model.restore()
        await model.waitForAlarmOperations()
        _ = dirPath.withCString { chmod($0, 0o700) }
        #expect(writes.value == 1)
        #expect(model.canonicalTimer == nil)
        #expect(model.makeWatchSnapshot().status == "idle")
        #expect(watchCount(defaults) == baseline)
        #expect(scheduler.operations.isEmpty)
        #expect(model.snapshotLoadFailure == nil)
        let fileState = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        )
        #expect(fileState.bootstrapUser != nil)
    }

    @Test @MainActor
    func uncertainReplacementQuarantinesWithoutEarlyPublish() async throws {
        let scenario = "bootstrap-legacy-ownership-remote"
        let suite = "PomodoroughTests.R50AP02Uncertain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let bytes = try JSONEncoder.api.encode(emptyInitial())
        try AtomicDurableFileStore(fileURL: storeURL).write(bytes)
        defaults.set(bytes, forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let writes = LockedValue(value: 0)
        let store = AtomicDurableFileStore(fileURL: storeURL, afterReplacement: {
            writes.set(writes.value + 1)
            if writes.value == 2 { throw POSIXError(.EIO) }
        })
        let model = makeEnv(scenario: scenario, store: store, dir: dir, defaults: defaults, scheduler: scheduler)
        let baseline = watchCount(defaults)
        await model.restore()
        await model.waitForAlarmOperations()
        #expect(writes.value == 2)
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.canonicalTimer == nil)
        #expect(model.makeWatchSnapshot().status == "idle")
        #expect(watchCount(defaults) == baseline)
        #expect(scheduler.operations.isEmpty)
        let durable = try #require(try AtomicDurableFileStore(fileURL: storeURL).read())
        #expect(durable != bytes)
    }

    @Test @MainActor
    func writableCommitsRunningAndClearsRequest() async throws {
        let scenario = "bootstrap-legacy-ownership-remote"
        let suite = "PomodoroughTests.R50AP02Writable.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspace.json")
        let bytes = try JSONEncoder.api.encode(emptyInitial())
        try AtomicDurableFileStore(fileURL: storeURL).write(bytes)
        defaults.set(bytes, forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = makeEnv(scenario: scenario, store: AtomicDurableFileStore(fileURL: storeURL), dir: dir, defaults: defaults, scheduler: scheduler)
        await model.restore()
        await model.waitForAlarmOperations()
        #expect(model.snapshotLoadFailure == nil)
        #expect(model.canonicalTimer?.status == .running)
        #expect(try persisted(defaults).pendingBootstrapResolution == nil)
        #expect(try persisted(defaults).bootstrapUser == nil)
        #expect(model.makeWatchSnapshot().status == "running")
    }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(value: Int) { _value = value }
    var value: Int { lock.withLock { _value } }
    func set(_ new: Int) { lock.withLock { _value = new } }
}
