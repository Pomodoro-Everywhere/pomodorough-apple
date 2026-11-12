import Foundation
import Testing
#if os(iOS)
import WatchConnectivity
#endif
@testable import Pomodorough

/// R54-AP02: a durable bootstrap install replaces the account workspace, so
/// it rotates the Watch workspace epoch. A deferred Watch setting queued
/// against the pre-install workspace is then rejected as stale instead of
/// mutating the installed remote workspace. A failed install keeps the
/// pre-install workspace and its epoch. Each test reads the persisted
/// workspace file and the persisted epoch key. The epoch rotates before the
/// install publishes, so the first post-install Watch snapshot already
/// carries it, and a stale setting delivered by the Watch is answered with
/// a corrective snapshot push (iOS only; macOS has no Watch session).
@Suite("R54-AP02 bootstrap install rotates the Watch workspace epoch", .serialized)
struct R54AP02BootstrapWatchEpochTests {
    @Test @MainActor
    func chosenKeepRemoteInstallRejectsPreInstallWatchSetting() async throws {
        let env = try R54AP02Environment(scenario: "bootstrap-r54ap02-choice-\(UUID().uuidString)")
        defer { env.cleanup() }
        try env.seed(R54AP02Environment.localHistoryBootstrapState())
        let model = env.model()
        await model.restore()
        try #require(model.historyResolutionState == .choosing)
        let before = try #require(model.makeWatchSnapshot().workspaceGeneration)
        let stale = try #require(env.queuedWireCommand(model, focusMinutes: 37))
        #expect(stale.workspaceGeneration == before)
        model.requestHistoryResolution(.keepRemote)
        #expect(model.historyResolutionState == .confirming(.keepRemote))
        let published = env.epochAtFirstPublication(model)
        await model.confirmHistoryResolution()
        await model.waitForAlarmOperations()
        #expect(model.historyResolutionState == .none)
        let installed = try env.savedState()
        #expect(installed.cachedUser != nil)
        #expect(installed.pendingDurationOperations.isEmpty)
        #expect(installed.settings.minutes(for: .focus) == 25)
        let after = try env.expectRotatedEpoch(model, from: before)
        #expect(published.value == after.uuidString)
        try env.expectStaleSettingRejected(model, stale, focusMinutes: 25)
        let reopened = env.model()
        #expect(!reopened.applyWatchCommand(stale, isDeferred: true))
        let current = try #require(env.queuedWireCommand(reopened, focusMinutes: 37))
        #expect(current.workspaceGeneration == after)
        #expect(reopened.applyWatchCommand(current, isDeferred: true))
        #expect(reopened.durationMinutes(for: .focus) == 37)
    }

    @Test @MainActor
    func automaticKeepRemoteInstallRejectsPreInstallWatchSetting() async throws {
        let env = try R54AP02Environment(scenario: "bootstrap-r54ap02-auto-\(UUID().uuidString)")
        defer { env.cleanup() }
        try env.seed(R54AP02Environment.emptyBootstrapState())
        let model = env.model()
        let before = try #require(model.makeWatchSnapshot().workspaceGeneration)
        let stale = try #require(env.queuedWireCommand(model, focusMinutes: 37))
        #expect(stale.workspaceGeneration == before)
        await model.restore()
        await model.waitForAlarmOperations()
        #expect(model.historyResolutionState == .none)
        #expect(model.snapshotLoadFailure == nil)
        let installed = try env.savedState()
        #expect(installed.cachedUser != nil)
        #expect(installed.pendingBootstrapResolution == nil)
        _ = try env.expectRotatedEpoch(model, from: before)
        try env.expectStaleSettingRejected(model, stale, focusMinutes: 25)
    }

#if os(iOS)
    // The stale setting arrives the way a queued Watch command does, over
    // transferUserInfo. The phone rejects it and pushes its current
    // snapshot at once; each push stamps the next snapshot sequence.
    @Test @MainActor
    func staleDeliveredWatchSettingPushesCurrentSnapshot() async throws {
        let env = try R54AP02Environment(scenario: "bootstrap-r54ap02-push-\(UUID().uuidString)")
        defer { env.cleanup() }
        try env.seed(R54AP02Environment.emptyBootstrapState())
        let model = env.model()
        let before = try #require(model.makeWatchSnapshot().workspaceGeneration)
        let stale = try #require(env.queuedWireCommand(model, focusMinutes: 37))
        await model.restore()
        await model.waitForAlarmOperations()
        _ = try env.expectRotatedEpoch(model, from: before)
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.resetForTesting()
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        await r54ap02MainQueueBarrier()
        let pushes = env.pushCount()
        model.watchSync.session(
            WCSession.default, didReceiveUserInfo: [WatchSyncKeys.command: try JSONEncoder().encode(stale)]
        )
        try await r54ap02Eventually { recorded.value.contains("stale_workspace") }
        await r54ap02MainQueueBarrier()
        #expect(env.pushCount() == pushes + 1)
        #expect(model.durationMinutes(for: .focus) == 25)
    }
#endif

    // Control: the request record commits, then the install write is
    // denied. The pre-install workspace stays durable, so its epoch stays.
    @Test @MainActor
    func deniedBootstrapInstallKeepsWatchEpoch() async throws {
        let env = try R54AP02Environment(scenario: "bootstrap-r54ap02-denied-\(UUID().uuidString)")
        defer { env.cleanup() }
        try env.seed(R54AP02Environment.emptyBootstrapState())
        let writes = LockedTestValue<Int>(0)
        let deniedAfter = LockedTestValue<Int?>(nil)
        let directoryPath = env.directory.path
        let fileURL = env.url
        // Deny every write once the durable file carries the request record,
        // so the resolve request goes out and only the install write fails.
        let store = AtomicDurableFileStore(fileURL: fileURL, afterReplacement: {
            writes.value += 1
            guard deniedAfter.value == nil,
                  let bytes = try? Data(contentsOf: fileURL),
                  let state = try? JSONDecoder.api.decode(PersistedTimerState.self, from: bytes),
                  state.pendingBootstrapResolution != nil else { return }
            deniedAfter.value = writes.value
            _ = directoryPath.withCString { chmod($0, 0o555) }
        })
        let model = env.model(store: store)
        let before = try #require(model.makeWatchSnapshot().workspaceGeneration)
        await model.restore()
        await model.waitForAlarmOperations()
        _ = directoryPath.withCString { chmod($0, 0o700) }
        #expect(deniedAfter.value != nil)
        #expect(writes.value == deniedAfter.value)
        #expect(model.snapshotLoadFailure == nil)
        #expect(TestFixtures.recordedRequests(for: env.scenario).contains {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let fileState = try env.savedState()
        #expect(fileState.bootstrapUser != nil)
        #expect(fileState.cachedUser == nil)
        #expect(fileState.pendingBootstrapResolution != nil)
        #expect(model.makeWatchSnapshot().workspaceGeneration == before)
        #expect(env.defaults.string(forKey: R54AP02Environment.epochKey) == before.uuidString)
    }
}

@MainActor
private final class R54AP02Environment {
    static let epochKey = "watch-workspace-generation-v1"

    let scenario: String
    let suiteName = "PomodoroughTests.R54AP02.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54AP02-\(UUID().uuidString)", isDirectory: true)
    let defaults: UserDefaults
    let session: URLSession
    private let models = NSHashTable<AppModel>.weakObjects()
    var url: URL { directory.appendingPathComponent("workspace.json") }

    init(scenario: String) throws {
        self.scenario = scenario
        defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = TestFixtures.session(for: scenario)
    }

    func cleanup() {
        _ = directory.path.withCString { chmod($0, 0o700) }
        // Invalidate only once every model built here is gone. A model that a
        // failed expectation left syncing must not create a task on an
        // invalidated session, which raises an uncaught NSException and
        // aborts the whole test process, so a live model only gets its tasks
        // cancelled.
        if models.allObjects.isEmpty {
            session.invalidateAndCancel()
        } else {
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seed(_ state: PersistedTimerState) throws {
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
    }

    func model(store: AtomicDurableFileStore? = nil) -> AppModel {
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            durableLocalStore: store ?? AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        models.add(model)
        return model
    }

    // Records the persisted epoch when the install assigns its first
    // projected value. installPreparedPublication assigns these before it
    // pushes the Watch snapshot, so this is the epoch that snapshot carries.
    func epochAtFirstPublication(_ model: AppModel) -> LockedTestValue<String?> {
        let observed = LockedTestValue<String?>(nil)
        let suiteName = suiteName
        let key = Self.epochKey
        withObservationTracking {
            _ = (model.canonicalTimer, model.history, model.tasks)
        } onChange: {
            observed.value = UserDefaults(suiteName: suiteName)?.string(forKey: key)
        }
        return observed
    }

    func pushCount() -> Int {
        defaults.integer(forKey: "watch-snapshot-seq-count")
    }

    func savedBytes() throws -> Data {
        try #require(try AtomicDurableFileStore(fileURL: url).read())
    }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: savedBytes())
    }

    // Plans a deferred focus-duration setting through the production send
    // planner, then round-trips it through the wire encoding.
    func queuedWireCommand(_ model: AppModel, focusMinutes: Int) -> WatchTimerCommand? {
        let planned = planWatchCommandSend(
            .setDuration(minutes: focusMinutes, forPhaseRawValue: "focus"),
            snapshot: model.makeWatchSnapshot(), isActivated: true, isReachable: false)
        guard case .queued(let queued) = planned,
              let data = try? JSONEncoder().encode(queued) else { return nil }
        return try? JSONDecoder().decode(WatchTimerCommand.self, from: data)
    }

    func expectRotatedEpoch(_ model: AppModel, from before: UUID) throws -> UUID {
        let after = try #require(model.makeWatchSnapshot().workspaceGeneration)
        #expect(after != before)
        #expect(defaults.string(forKey: Self.epochKey) == after.uuidString)
        return after
    }

    func expectStaleSettingRejected(
        _ model: AppModel, _ stale: WatchTimerCommand, focusMinutes: Int
    ) throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.resetForTesting()
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let installedBytes = try savedBytes()
        let pending = model.pendingDurationOperationCount
        #expect(!model.applyWatchCommand(stale, isDeferred: true))
        #expect(recorded.value.contains("stale_workspace"))
        #expect(model.durationMinutes(for: .focus) == focusMinutes)
        #expect(model.pendingDurationOperationCount == pending)
        #expect(try savedBytes() == installedBytes)
    }

    static func emptyBootstrapState() -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        return state
    }

    // Local history plus never-sent work, so restore stops at the chooser.
    static func localHistoryBootstrapState() throws -> PersistedTimerState {
        var state = emptyBootstrapState()
        state.pendingCommands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
        ]
        let task = try #require(FocusTask(title: "Local task"))
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-local-task", taskId: task.id.uuidString.lowercased(),
            type: .upsert, title: task.title, occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002, hlcCounter: 0
        )]
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-bootstrap", phase: .focus, durationMs: 30 * 60_000, wallMs: 3
        )]
        for command in state.pendingCommands { state.recordNeverSentCommand(id: command.id) }
        for operation in state.pendingTaskOperations { state.recordNeverSentTaskOperation(id: operation.id) }
        for operation in state.pendingDurationOperations {
            state.recordNeverSentDurationOperation(id: operation.id)
        }
        return state
    }
}

#if os(iOS)
@MainActor
private func r54ap02Eventually(_ predicate: () -> Bool) async throws {
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(predicate())
}

// The main actor runs jobs from the serial main queue in FIFO order, so a
// block enqueued here runs after every main-actor job already enqueued.
@MainActor
private func r54ap02MainQueueBarrier() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
#endif
