import Foundation
import Testing
@testable import Pomodorough

@Suite("History Resolution Offline Escape")
struct HistoryResolutionOfflineEscapeTests {
    @Test @MainActor
    func offlinePreflightLaunchBlocksWithRetryOnly() async throws {
        let scenario = "bootstrap-preflight-offline"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try preflightState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(nil))
        #expect(model.isOffline)
        #expect(model.isHistoryResolutionBlocking)
        #expect(model.isHistoryResolutionOfflineEscapeAllowed)
        #expect(!model.isHistoryResolutionOfflineEscapeActive)
        #expect(model.isWorkspaceMutationBlocked)
        let persisted = try persistedState(defaults)
        #expect(persisted.bootstrapUser == TestFixtures.user)
        #expect(persisted.pendingBootstrapResolution == nil)
        #expect(persisted.pendingCommands == initial.pendingCommands)
        #expect(persisted.pendingTaskOperations == initial.pendingTaskOperations)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/bootstrap/resolve" })
    }

    @Test @MainActor
    func offlineEscapeReachesLocalTimerPreservingRecovery() async throws {
        let scenario = "bootstrap-preflight-offline"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try preflightState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        model.continueHistoryResolutionOffline()

        #expect(model.isHistoryResolutionOfflineEscapeActive)
        #expect(!model.isHistoryResolutionBlocking)
        #expect(!model.isWorkspaceMutationBlocked)
        let before = model.pendingChangeCount
        model.setDurationMinutes(45, for: .focus)
        #expect(model.pendingChangeCount == before + 1)
        let persisted = try persistedState(defaults)
        #expect(persisted.bootstrapUser == TestFixtures.user)
        #expect(persisted.pendingBootstrapResolution == nil)
        #expect(persisted.pendingDurationOperations.count == 1)
        model.returnToHistoryResolution()
        #expect(!model.isHistoryResolutionOfflineEscapeActive)
        #expect(model.isHistoryResolutionBlocking)
    }

    @Test @MainActor
    func relaunchAfterEscapeReblocksWithoutLosingWork() async throws {
        let scenario = "bootstrap-preflight-offline"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try preflightState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        model.continueHistoryResolutionOffline()
        model.setDurationMinutes(45, for: .focus)
        let escaped = try persistedState(defaults)

        let relaunched = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(!relaunched.isHistoryResolutionOfflineEscapeActive)
        #expect(relaunched.isHistoryResolutionBlocking)
        await relaunched.restore()
        #expect(relaunched.historyResolutionState == .retryable(nil))
        #expect(relaunched.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults).pendingCommands == escaped.pendingCommands)
        #expect(try persistedState(defaults).pendingDurationOperations == escaped.pendingDurationOperations)
        #expect(try persistedState(defaults).bootstrapUser == TestFixtures.user)
    }

    @Test @MainActor
    func submittedReconciliationStaysRetryOnly() async throws {
        let scenario = "bootstrap-network-retry"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try submittedState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isHistoryResolutionOfflineEscapeAllowed)
        model.continueHistoryResolutionOffline()
        #expect(!model.isHistoryResolutionOfflineEscapeActive)
        #expect(model.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults).pendingBootstrapResolution == request)
        #expect(try persistedState(defaults).bootstrapUser == TestFixtures.user)
    }

    @Test @MainActor
    func reconnectAfterEscapeRetriesWithoutDuplication() async throws {
        let scenario = "bootstrap-preflight-offline-reconnect"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try preflightState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        model.continueHistoryResolutionOffline()

        await model.retryHistoryResolution()

        #expect(!model.isHistoryResolutionOfflineEscapeActive)
        #expect(model.historyResolutionState != .retryable(nil))
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 2)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
        #expect(try persistedState(defaults).pendingTaskOperations == initial.pendingTaskOperations)
        #expect(try persistedState(defaults).bootstrapUser == TestFixtures.user)
    }

    private func preflightState() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.settings.setMinutes(30, for: .focus)
        let task = try #require(FocusTask(title: "Offline queued task"))
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-offline-queued",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )]
        state.knownTasks = [task]
        return state
    }

    private func submittedState() throws -> PersistedTimerState {
        var state = try preflightState()
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-offline-escape",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .merge,
            commands: state.pendingCommands,
            taskOperations: state.pendingTaskOperations,
            durationOperations: [],
            autoStartOperations: []
        )
        return state
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }
}
