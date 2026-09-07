import Foundation
import Testing
@testable import Pomodorough

// AP25: Sentry capture at user-visible failure boundaries.
// Each test asserts the preserved user-visible outcome plus exactly one
// SentryCapture record, and that the record carries no PII (no tokens,
// titles, room IDs, or snapshot payloads).
@Suite("Sentry capture at failure boundaries")
struct SentryCaptureTests {
    @Test
    func captureForwardsToBackendOncePerKey() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let first = RecordingTokenStoreFailure.load
        let second = RecordingTokenStoreFailure.save
        SentryCapture.captureOnce(key: "sentry-once-a", error: first)
        SentryCapture.captureOnce(key: "sentry-once-a", error: second)
        SentryCapture.captureOnce(key: "sentry-once-b", error: second)
        #expect(recorded.value.count == 2)
    }

    @Test
    func resetClearsOnceKeysForTestIsolation() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        SentryCapture.captureOnce(key: "sentry-reset", error: RecordingTokenStoreFailure.load)
        SentryCapture.resetForTesting()
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        SentryCapture.captureOnce(key: "sentry-reset", error: RecordingTokenStoreFailure.load)
        #expect(recorded.value.count == 2)
    }

    @Test
    func deleteDetachedCredentialFailureReturnsFalseAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let tokens = TokenPair(
            accessToken: "sentry-access", accessTokenExpiresAt: .distantFuture,
            refreshToken: "sentry-refresh", refreshTokenExpiresAt: .distantFuture
        )
        let store = RecordingTokenStore(tokens: tokens, failures: [.load])
        let client = APIClient(keychain: store)
        #expect(await client.deleteDetachedCredential(refreshToken: "sentry-refresh") == false)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("sentry-access"))
        #expect(!recorded.value[0].contains("sentry-refresh"))
    }

    @Test
    func revokeRefreshFailureReturnsRetryAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "sentry-capture-revoke-refresh-\(UUID().uuidString)"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        let obligation = LogoutRevocationObligation(
            tokens: TokenPair(
                accessToken: "revoke-access", accessTokenExpiresAt: .distantFuture,
                refreshToken: "revoke-refresh", refreshTokenExpiresAt: .distantFuture
            ),
            requiresRefresh: true
        )
        #expect(await client.revoke(obligation) == .retry)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("revoke-refresh"))
    }

    @Test
    func deleteAccountTransportFailureStaysUnknownAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "apple-api-coverage-account-delete-transport"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Transport failure must stay unknown")
            return
        }
        #expect(recorded.value.count == 1)
    }

    @Test
    func submitRevocationServerFailureReturnsRetryAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "apple-api-coverage-logout-server-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        let obligation = LogoutRevocationObligation(
            tokens: TokenPair(
                accessToken: "logout-access", accessTokenExpiresAt: .distantFuture,
                refreshToken: "logout-refresh", refreshTokenExpiresAt: .distantFuture
            )
        )
        #expect(await client.revoke(obligation) == .retry)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("logout-access"))
    }

    @Test @MainActor
    func addTaskCoreFailureReturnsFalseAndCapturesWithoutTitle() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryAddTask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "PomodoroughTests.SentryAddTask.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()),
            defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        #expect(await model.addTask("Secret Task Title") == false)
        #expect(model.errorMessage != nil)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Task Title"))
    }

    @Test @MainActor
    func journalSaveFailureQuarantinesDeletionAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.SentryJournalSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryJournalSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let journalURL = directory.appendingPathComponent("deletion.json")
        let journal = AccountDeletionJournal(
            fileURL: journalURL,
            beforeSave: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: journal,
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        await model.deleteAccount(confirmation: "DELETE")
        #expect(model.errorMessage?.contains("could not be saved") == true)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func journalClearFailureThrowsAndCapturesWithoutRoomIDs() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryJournalClear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = AccountDeletionJournal(
            fileURL: directory.appendingPathComponent("deletion.json"),
            beforeClear: { throw CocoaError(.fileWriteUnknown) }
        )
        try journal.save(.init(phase: .prepared, roomIDs: ["secret-room"]))
        let suiteName = "PomodoroughTests.SentryJournalClear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: journal,
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        #expect(model.clearAccountDeletionState() == false)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("secret-room"))
    }

    @Test
    func corruptWatchCommandDecodeCapturesOnceAndStaysSilent() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        for payload in [Data("not-json".utf8), Data("{bad".utf8)] {
            do {
                _ = try JSONDecoder().decode(WatchTimerCommand.self, from: payload)
            } catch {
                WatchSyncService.commandDecodeFailed(error)
            }
        }
        #expect(recorded.value.count == 1)
    }

    @Test
    func flakyWatchReportSendCapturesOnce() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        WatchSyncService.reportSendFailed(URLError(.notConnectedToInternet))
        WatchSyncService.reportSendFailed(URLError(.timedOut))
        #expect(recorded.value.count == 1)
    }

    @Test
    func watchLogDedupeKeepsRepeatsSilent() {
        let key = "watch-dedupe-\(UUID().uuidString)"
        #expect(WatchSyncLogDedupe.shouldLog(key: key) == true)
        #expect(WatchSyncLogDedupe.shouldLog(key: key) == false)
        #expect(WatchSyncLogDedupe.shouldLog(key: key + "-other") == true)
    }

    // AP29: room Iroh failure boundaries keep their user-visible outcome and
    // capture exactly once with no PII (no room names, IDs, or secrets).
    @Test @MainActor
    func roomCreateServiceFailureStaysFailedAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .offline)
        await fixture.service.setStartError(SentryRoomServiceError.endpointUnavailable)
        let transition = await fixture.controller.createRoom(
            name: "Secret Room Name",
            environment: sentryRoomEnvironment()
        )
        #expect(transition == .failed(SentryRoomServiceError.endpointUnavailable.localizedDescription))
        #expect(fixture.store.activeRoomID == nil)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Room Name"))
    }

    @Test @MainActor
    func roomPrepareStateSuspendFailureStaysFailedAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .iroh)
        let transition = await fixture.controller.changeMode(
            to: .offline,
            environment: sentryRoomEnvironment()
        )
        guard case .failed = transition else {
            Issue.record("Expected failed, got \(transition)")
            return
        }
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func roomActivateFailureStaysFailedAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .offline)
        let secret = Data(repeating: 5, count: 32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try fixture.store.prepareJoinedRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Secret Join Name",
            returnState: .fresh(),
            initialPeer: IrohPeer(
                endpointID: "endpoint-sentry0001",
                endpointTicket: "endpoint-ticket-sentry0001",
                deviceID: nil,
                displayName: nil,
                lastSeenAt: nil
            )
        )
        let transition = await fixture.controller.changeMode(
            to: .iroh,
            environment: sentryRoomEnvironment()
        )
        guard case .failed = transition else {
            Issue.record("Expected failed, got \(transition)")
            return
        }
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Join Name"))
        #expect(!recorded.value[0].contains(roomID))
    }

    @Test @MainActor
    func roomLeaveSuspendFailureStaysFailedAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .iroh)
        let transition = await fixture.controller.leaveRoom(
            environment: sentryRoomEnvironment()
        )
        guard case .failed = transition else {
            Issue.record("Expected failed, got \(transition)")
            return
        }
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func roomStartFailureReportsUnavailableAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .iroh)
        let secret = Data(repeating: 9, count: 32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        var local = PersistedTimerState.fresh()
        local.deviceId = "device-sentry-start"
        _ = try fixture.store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Secret Start Room",
            returnState: local,
            genesis: sentryRoomGenesis(from: local)
        )
        await fixture.service.setStartError(SentryRoomServiceError.endpointUnavailable)
        let roomState = try #require(fixture.store.activeRoomState)
        fixture.workspace.value = sentryRoomWorkspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: sentryRoomEnvironment(for: roomState))
        let expected = RoomReplicationEvent.statusChanged(
            .unavailable(SentryRoomServiceError.endpointUnavailable.localizedDescription)
        )
        for _ in 0..<200 {
            if fixture.events.value.contains(expected) { break }
            await Task.yield()
        }
        #expect(fixture.events.value.contains(expected))
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Start Room"))
        #expect(!recorded.value[0].contains(roomID))
    }

    @Test
    func corruptRoomStoreLoadStaysEmptyAndCapturesWithoutSecrets() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryRoomStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "sentry-room-secret not-json".write(
            to: directory.appendingPathComponent("rooms.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = IrohRoomStore(
            fileURL: directory.appendingPathComponent("rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        #expect(store.activeSnapshot == nil)
        #expect(store.roomIDs.isEmpty)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("sentry-room-secret"))
    }

    @Test @MainActor
    func accountRestoreFailureStaysLocalOnlyAndCapturesWithoutTokens() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let store = RecordingTokenStore(
            tokens: TokenPair(
                accessToken: "restore-access", accessTokenExpiresAt: .distantFuture,
                refreshToken: "restore-refresh", refreshTokenExpiresAt: .distantFuture
            ),
            failures: [.load]
        )
        let controller = AccountLifecycleController(
            api: APIClient(keychain: store),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        let transition = await controller.restore(cachedUser: TestFixtures.user)
        #expect(transition == .localOnly(invalidatesSynchronization: false))
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("restore-access"))
        #expect(!recorded.value[0].contains("restore-refresh"))
    }

    @Test
    func revocationRetryCancelStaysSilentWithoutCapture() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let store = TestLogoutRevocationStore()
        try store.append(LogoutRevocationObligation(tokens: TokenPair(
            accessToken: "revocation-access", accessTokenExpiresAt: .distantFuture,
            refreshToken: "revocation-refresh", refreshTokenExpiresAt: .distantFuture
        )))
        let controller = SessionRevocationController(
            revoker: SentryRetryRevoker(result: .retry),
            store: store,
            retryDelay: .milliseconds(50),
            storageReadRetryDelays: [.milliseconds(50)]
        )
        await controller.resumePending()
        try await Task.sleep(for: .milliseconds(200))
        await controller.cancelRetry()
        #expect(await controller.isRetryRunning == false)
        #expect(recorded.value.count == 0)
    }

#if os(iOS)
    @Test
    func liveActivityStartFailureCapturesOnceAndKeepsTimerUnaffected() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        TimerLiveActivityCoordinator.startFailed(URLError(.notConnectedToInternet))
        TimerLiveActivityCoordinator.startFailed(URLError(.timedOut))
        #expect(recorded.value.count == 1)
    }
#endif

    @Test
    func sentrySetupWithoutDSNReturnsWithoutCrashing() {
        SentrySetup.startIfConfigured()
    }

    // AP29: compact room fixture mirroring RoomReplicationControllerTests so
    // Sentry tests drive the real controller failure boundaries.
    @MainActor
    private func sentryRoomFixture(mode: ReplicationMode) -> SentryRoomFixture {
        let store = IrohRoomStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SentryRoom-\(UUID().uuidString)")
                .appendingPathComponent("rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let service = SentryRoomServiceStub()
        let state = LockedTestValue(RoomReplicationCentralizedState(
            sessionGeneration: 7,
            isSignedIn: true,
            isWorkspaceMutationBlocked: false,
            isSessionVerified: true,
            localRevision: 0,
            isSyncing: false,
            isTimerActive: false,
            isHistoryResolutionBlocking: false
        ))
        let events = LockedTestValue<[RoomReplicationEvent]>([])
        let operations = LockedTestValue<[RoomReplicationOperation]>([])
        let workspace = LockedTestValue(sentryRoomWorkspace(from: .fresh()))
        let dependencies = RoomReplicationController.Dependencies(
            roomStore: store,
            retryDelay: .seconds(5),
            centralizedState: { state.value },
            workspaceSnapshot: { workspace.value },
            revisionEvents: { AsyncThrowingStream { $0.finish() } },
            sleep: { _ in throw CancellationError() },
            secureRandomBytes: { _ in Data(repeating: 7, count: 32) },
            encodeInvite: { _, _, _, _ in "encoded-invite" },
            makeService: { _ in service }
        )
        let controller = RoomReplicationController(
            mode: mode,
            dependencies: dependencies,
            eventHandler: { event in events.value.append(event) },
            operationHandler: { operation in operations.value.append(operation) }
        )
        return SentryRoomFixture(
            controller: controller,
            store: store,
            service: service,
            events: events,
            operations: operations,
            workspace: workspace
        )
    }

    @MainActor
    private func sentryRoomEnvironment(for state: PersistedTimerState = .fresh()) -> RoomReplicationEnvironment {
        RoomReplicationEnvironment(deviceID: state.deviceId, displayName: nil, platform: "macos")
    }

    private func sentryRoomWorkspace(from state: PersistedTimerState) -> RoomReplicationWorkspaceSnapshot {
        RoomReplicationWorkspaceSnapshot(state: state, genesis: sentryRoomGenesis(from: state))
    }

    private func sentryRoomGenesis(from state: PersistedTimerState) -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: state.canonicalTimer,
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
    }
}

private enum SentryRoomServiceError: Error {
    case endpointUnavailable
}

private actor SentryRoomServiceStub: RoomReplicationServing {
    private(set) var startedContexts: [IrohServiceContext] = []
    private var startError: SentryRoomServiceError?

    func setStartError(_ error: SentryRoomServiceError?) {
        startError = error
    }

    func start(_ context: IrohServiceContext) async throws -> String {
        startedContexts.append(context)
        if let startError { throw startError }
        return "endpoint-ticket"
    }

    func stop() async {}
    func currentEndpointTicket() async throws -> String { "endpoint-ticket" }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}

@MainActor
private struct SentryRoomFixture {
    let controller: RoomReplicationController
    let store: IrohRoomStore
    let service: SentryRoomServiceStub
    let events: LockedTestValue<[RoomReplicationEvent]>
    let operations: LockedTestValue<[RoomReplicationOperation]>
    let workspace: LockedTestValue<RoomReplicationWorkspaceSnapshot>
}

private struct SentryRetryRevoker: LogoutRevoking, Sendable {
    let result: LogoutRevocationResult

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        result
    }
}
