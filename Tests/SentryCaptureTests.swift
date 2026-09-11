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
        // Isolate the addTask boundary: init already ran rebuildOptimisticState
        // (AP31) without a backend, so only addTask itself is recorded below.
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
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

    // AP31: silent persistence, migration, replication, and model boundaries
    // keep their user-visible outcome and capture Error-only with no PII.
    // Watch log-only paths are unchanged and not covered here.
    @Test @MainActor
    func rebuildFailureFallsBackAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryRebuild.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryRebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        #expect(model.rebuildOptimisticState() == false)
        #expect(model.errorMessage != nil)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func workspaceMutationFailureKeepsStateAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryMutation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryMutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        model.start()
        #expect(model.errorMessage != nil)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func alarmScheduleFailureReportsAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryAlarm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryAlarm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = RecordingAlarmScheduler()
        scheduler.schedulingError = URLError(.notConnectedToInternet)
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: scheduler
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        model.start()
        for _ in 0..<100 {
            if recorded.value.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorded.value.count == 1)
        #expect(model.errorMessage != nil)
    }

    @Test @MainActor
    func alarmCancelFailureWithoutErrorReportStillCapturesAndStaysSilent() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryAlarmCancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryAlarmCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: scheduler
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        model.start()
        await model.waitForAlarmOperations()
        let timerID = try #require(model.canonicalTimer?.id)
        scheduler.cancellationError = URLError(.notConnectedToInternet)
        model.adoptRoomWorkspace(PersistedTimerState.fresh())
        await model.waitForAlarmOperations()
        #expect(recorded.value.count == 1)
        #expect(model.errorMessage == nil)
        #expect(model.canonicalTimer == nil)
        #expect(scheduler.operations.contains(.cancel(timerID: timerID)))
    }

    @Test @MainActor
    func irohCompletionFailureKeepsMessageAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryIrohCompletion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryIrohCompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        model.completeIrohTimerIfNeeded(
            TestFixtures.timer(status: .running, elapsed: 1_000), at: TestFixtures.anchor
        )
        #expect(model.errorMessage != nil)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func purgeAccountDataFailureQuarantinesAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryPurge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryPurge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = MemoryIrohRoomSecretStore(secrets: ["stuck-room-secret": Data(repeating: 3, count: 32)])
        secrets.setDeleteFailure(true, roomID: "stuck-room-secret")
        let roomStore = IrohRoomStore(
            fileURL: dir.appendingPathComponent("rooms.json"), secretStore: secrets
        )
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: roomStore, alarmScheduler: RecordingAlarmScheduler()
        )
        defaults.set(try JSONEncoder().encode([String]()), forKey: "account-deletion-room-ids-v1")
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        await model.finishConfirmedAccountDeletion()
        #expect(model.errorMessage?.contains("room cleanup") == true)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("stuck-room-secret"))
    }

    @Test @MainActor
    func snapshotLoadFailureFallsBackAndCaptures() throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryLoad.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("sentry-secret-task".utf8), forKey: PersistedStateLoader.storageKey)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryLoad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = AppStatePersistenceCoordinator(
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: dir)
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let roomStore = TestFixtures.emptyIrohRoomStore(in: dir)
        let transition = coordinator.load(
            replicationMode: .centralized, roomStore: roomStore,
            wallDate: TestFixtures.anchor, uptime: 100
        )
        #expect(transition.snapshotLoadFailure != nil)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("sentry-secret-task"))
    }

    @Test @MainActor
    func persistLocalWriteFailureStaysFailedAndCaptures() throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryPersist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryPersist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: blocker)
        let store = AtomicDurableFileStore(fileURL: blocker.appendingPathComponent("state.json"))
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults, durableLocalStore: store)
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let result = coordinator.persist(PersistedTimerState.fresh(), to: .local)
        guard case .failed = result else { Issue.record("Expected failed"); return }
        #expect(recorded.value.count == 1)
    }

    @Test
    func autoStartMigrationFailureMarksFailedAndCaptures() throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryAutoStart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try sentryStrippedTimerJSON(removing: ["pendingAutoStartOperations"]),
            forKey: PersistedStateLoader.storageKey)
        let loader = PersistedStateLoader(defaults: defaults)
        let load = loader.load()
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let transition = loader.migrating(.fresh(), from: load, replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 0), uptime: 100, roomStore: nil)
        #expect(transition.migrationFailed)
        #expect(recorded.value.count == 1)
    }

    @Test
    func legacyTasksMigrationFailureMarksFailedAndCaptures() throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryLegacyTasks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder.api.encode(PersistedTimerState.fresh()),
            forKey: PersistedStateLoader.storageKey)
        let task = try #require(FocusTask(title: "Secret Legacy Task"))
        let legacy = LocalTaskState(tasks: [task], selectedTaskID: task.id, assignments: [:])
        defaults.set(try JSONEncoder.api.encode(legacy), forKey: PersistedStateLoader.localTaskStorageKey)
        let loader = PersistedStateLoader(defaults: defaults)
        let load = loader.load()
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let transition = loader.migrating(.fresh(), from: load, replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 0), uptime: 100, roomStore: nil)
        #expect(transition.migrationFailed)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Legacy Task"))
    }

    // AP74: corrupt local-tasks-v1 is decode failure, not absence.
    // Migration is skipped, the blob is kept, capture fires once.
    // MainActor: SentryCapture backend is global.
    @Test @MainActor
    func corruptLegacyTaskBlobSkipsMigrationAndCapturesOnce() throws {
        SentryCapture.resetForTesting()
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryLegacyDecode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder.api.encode(PersistedTimerState.fresh()),
            forKey: PersistedStateLoader.storageKey)
        let corrupt = Data("corrupt-legacy-tasks".utf8)
        defaults.set(corrupt, forKey: PersistedStateLoader.localTaskStorageKey)
        let loader = PersistedStateLoader(defaults: defaults)
        let load = loader.load()
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let transition = loader.migrating(.fresh(), from: load, replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 0), uptime: 100, roomStore: nil)
        #expect(!transition.migrations.contains(.tasks))
        #expect(!transition.removesLegacyTasksAfterProjection)
        #expect(!transition.migrationFailed)
        #expect(recorded.value.count == 1)
        #expect(defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == corrupt)
        _ = loader.migrating(.fresh(), from: load, replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 0), uptime: 100, roomStore: nil)
        #expect(recorded.value.count == 1)
    }

    @Test
    func selectedTaskMigrationFailureMarksFailedAndCaptures() throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentrySelectedTask.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try sentryStrippedTimerJSON(removing: ["pendingSelectedTaskOperations"]),
            forKey: PersistedStateLoader.storageKey)
        let loader = PersistedStateLoader(defaults: defaults)
        let load = loader.load()
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let transition = loader.migrating(.fresh(), from: load, replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 0), uptime: 100, roomStore: nil)
        #expect(transition.migrationFailed)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func peerListFailureStaysUnavailableAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let statuses = LockedTestValue<[IrohConnectionStatus]>([])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryPeers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = IrohRoomStore(
            fileURL: dir.appendingPathComponent("rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let missingRoomID = try IrohProtocolV1.roomID(for: Data(repeating: 9, count: 32))
        let context = IrohServiceContext(roomID: missingRoomID,
            roomSecret: Data(repeating: 9, count: 32), deviceID: "device-sentry-test",
            displayName: nil, platform: "macos")
        let service = IrohReplicationService(store: store,
            keyStore: SentryTestKeyStore(),
            statusHandler: { status in var c = statuses.value; c.append(status); statuses.value = c },
            projectionHandler: { _, _ in })
        _ = try await service.start(context)
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        await service.syncNow()
        await service.stop()
        #expect(statuses.value.contains { if case .unavailable = $0 { return true }; return false })
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains(missingRoomID))
    }

    @Test @MainActor
    func committedRecordsCheckFailureStaysFalseAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryCommitted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = Data(repeating: 5, count: 32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let source = try JSONEncoder.api.encode(LocalTaskState(tasks: [], selectedTaskID: nil, assignments: [:]))
        let task1 = try #require(FocusTask(title: "Secret Committed Task"))
        let task2 = try #require(FocusTask(title: "Secret Missing Task"))
        let op1 = TaskOperation(id: "sentry-op-1", taskId: task1.id.uuidString.lowercased(),
            type: .upsert, title: task1.title, occurredAt: TestFixtures.anchor, hlcWallMs: 1_000_000, hlcCounter: 0)
        var base = PersistedTimerState.fresh()
        base.deviceId = "device-sentry-check"
        base.tasks = [task1]; base.knownTasks = [task1]
        base.pendingTaskOperations = [op1]
        base.irohLegacyTaskMigration = IrohLegacyTaskMigration(roomID: roomID, source: source, state: base)
        let store = IrohRoomStore(fileURL: dir.appendingPathComponent("rooms.json"),
            secretStore: MemoryIrohRoomSecretStore())
        _ = try store.createRoom(roomID: roomID, roomSecret: secret, name: "Secret Room",
            returnState: base, genesis: sentryEmptyGenesis())
        // Capture the receipt-bearing local state into the room: roomState
        // gains the receipt and op1 is committed, so the later extra op2 is
        // the only missing record when the coordinator re-checks.
        _ = try store.captureLocalOperations(from: base)
        let stored = try #require(store.activeRoomState)
        try #require(stored.irohLegacyTaskMigration == base.irohLegacyTaskMigration)
        let op2 = TaskOperation(id: "sentry-op-2", taskId: task2.id.uuidString.lowercased(),
            type: .upsert, title: task2.title, occurredAt: TestFixtures.anchor, hlcWallMs: 1_000_000, hlcCounter: 0)
        var migrated = stored
        migrated.pendingTaskOperations.append(op2)
        migrated.tasks.append(task2); migrated.knownTasks.append(task2)
        let api = APIClient(keychain: StaticTokenStore())
        let coordinator = CentralizedAccountSessionCoordinator(
            lifecycle: AccountLifecycleController(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: AccountSynchronization(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly), roomStore: store)
        let transition = AppStatePersistenceCoordinator.LoadTransition(
            replicationMode: .iroh, state: migrated, removesLegacyTasksAfterProjection: false,
            shouldPersistAfterProjection: false, shouldReportInvalidLocalClock: false,
            snapshotLoadFailure: nil, legacyTaskSource: source)
        coordinator.setLegacyMigrationForTesting(transition: transition, roomID: roomID)
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        #expect(coordinator.containsCommittedLegacyRecords(migrated, in: stored) == false)
        #expect(recorded.value.count == 1)
        if let first = recorded.value.first {
            #expect(!first.contains("Secret Committed Task"))
            #expect(!first.contains("Secret Missing Task"))
            #expect(!first.contains(roomID))
        }
    }

    // AP33: remaining silent try?/log-only sites keep their user-visible
    // outcome and capture Error-only with no PII. watchOS stays log-only by
    // design (no Sentry dependency); the iOS seams below are the captured side.
    @Test
    func watchSnapshotEncodeFailureCapturesOnce() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        WatchSyncService.snapshotEncodeFailed(URLError(.cannotParseResponse))
        WatchSyncService.snapshotEncodeFailed(URLError(.cannotDecodeContentData))
        #expect(recorded.value.count == 1)
    }

    @Test
    func watchContextUpdateFailureCapturesOnce() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        WatchSyncService.contextUpdateFailed(URLError(.notConnectedToInternet))
        WatchSyncService.contextUpdateFailed(URLError(.timedOut))
        #expect(recorded.value.count == 1)
    }

    @Test
    func irohEndpointCloseFailureCapturesWithoutTickets() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        IrohReplicationService.endpointCloseFailed(URLError(.cannotCloseFile))
        #expect(recorded.value.count == 1)
    }

    @Test
    func uiTestResetFailureCapturesWithoutTokens() {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        PomodoroughApp.uiTestResetFailed(
            KeychainError(operation: "delete", status: -25293, message: "test-reset"),
            step: "keychain-delete"
        )
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("sentry-access"))
    }

    @Test @MainActor
    func allowTimerAlertsAuthFailureCompletesIntroAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryAllowAlerts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryAllowAlerts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = RecordingAlarmScheduler()
        scheduler.authorizationError = URLError(.notConnectedToInternet)
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir), alarmScheduler: scheduler
        )
        #expect(model.needsPermissionIntroduction == true)
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        await model.allowTimerAlerts()
        #expect(model.needsPermissionIntroduction == false)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func corruptRoomIDsDecodeQuarantinesAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryRoomIDsDecode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryRoomIDsDecode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        defaults.set(Data("secret-room-corrupt".utf8), forKey: "account-deletion-room-ids-v1")
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler()
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        await model.finishConfirmedAccountDeletion()
        #expect(model.errorMessage?.contains("room cleanup") == true)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("secret-room-corrupt"))
    }

    @Test
    func detachLogoutKeychainDeleteFailureReturnsObligationAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let tokens = TokenPair(
            accessToken: "detach-access", accessTokenExpiresAt: .distantFuture,
            refreshToken: "detach-refresh", refreshTokenExpiresAt: .distantFuture
        )
        let store = RecordingTokenStore(tokens: tokens, failures: [.delete])
        let client = APIClient(keychain: store)
        #expect(try await client.restoreTokens() == true)
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let obligation = try await client.detachLogoutObligation(into: TestLogoutRevocationStore())
        #expect(obligation?.tokens.refreshToken == "detach-refresh")
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("detach-access"))
        #expect(!recorded.value[0].contains("detach-refresh"))
    }

    @Test @MainActor
    func restoreClearTokensFailureStaysLocalOnlyAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        let store = RecordingTokenStore(
            tokens: TokenPair(
                accessToken: "restore-clear-access", accessTokenExpiresAt: .distantFuture,
                refreshToken: "restore-clear-refresh", refreshTokenExpiresAt: .distantFuture
            ),
            failures: [.delete]
        )
        let controller = AccountLifecycleController(
            api: APIClient(keychain: store),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let transition = await controller.restore(cachedUser: nil)
        #expect(transition == .localOnly(invalidatesSynchronization: true))
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("restore-clear-access"))
        #expect(!recorded.value[0].contains("restore-clear-refresh"))
    }

    // AP36: remaining auth, phase, and invite boundaries keep their
    // user-visible outcome and capture Error-only with no PII.
    @Test @MainActor
    func authenticateTransportFailureStaysFailedAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "apple-api-coverage-account-delete-transport"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let controller = AccountLifecycleController(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        let operation = controller.currentOperation
        let secretDevice = "secret-device-auth-0001"
        let transition = await controller.authenticate(
            operation, deviceID: secretDevice, platform: "macos"
        )
        guard case .failed = transition else {
            Issue.record("Expected failed, got \(transition)")
            return
        }
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains(secretDevice))
    }

    @Test @MainActor
    func verifyRetryFailureStaysRetryAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let scenario = "apple-api-coverage-account-delete-transport"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())
        let controller = AccountLifecycleController(
            api: client,
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        let operation = controller.currentOperation
        let transition = await controller.verifyRestoredSession(
            operation, isSignedIn: true, hasAccountState: true
        )
        #expect(transition == .retry)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func clearTokensFailureStaysFalseAndCaptures() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let store = RecordingTokenStore(
            tokens: TokenPair(
                accessToken: "clear-access", accessTokenExpiresAt: .distantFuture,
                refreshToken: "clear-refresh", refreshTokenExpiresAt: .distantFuture
            ),
            failures: [.delete]
        )
        let controller = AccountLifecycleController(
            api: APIClient(keychain: store),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        #expect(await controller.clearTokens() == false)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("clear-access"))
        #expect(!recorded.value[0].contains("clear-refresh"))
    }

    @Test @MainActor
    func nextBreakPhaseFallbackKeepsSelectionAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        let suite = "PomodoroughTests.SentryNextBreak.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryNextBreak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(
            api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: dir),
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        #expect(model.nextBreakPhase() == .focus)
        #expect(recorded.value.count == 1)
    }

    @Test @MainActor
    func refreshInviteTicketFailureStaysFailedAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let fixture = sentryRoomFixture(mode: .iroh)
        let secret = Data(repeating: 11, count: 32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        var local = PersistedTimerState.fresh()
        local.deviceId = "device-sentry-invite"
        _ = try fixture.store.createRoom(
            roomID: roomID, roomSecret: secret, name: "Secret Invite Room",
            returnState: local, genesis: sentryRoomGenesis(from: local)
        )
        let roomState = try #require(fixture.store.activeRoomState)
        fixture.workspace.value = sentryRoomWorkspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: sentryRoomEnvironment(for: roomState))
        await fixture.service.setTicketError(.endpointUnavailable)
        let transition = await fixture.controller.refreshInvite(
            environment: sentryRoomEnvironment(for: roomState)
        )
        guard case .failed = transition else {
            Issue.record("Expected failed, got \(transition)")
            return
        }
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("Secret Invite Room"))
        #expect(!recorded.value[0].contains(roomID))
    }

    // AP78: AlarmKit fallback still notifies and captures once.
    @Test @MainActor
    func timerAlarmScheduleFallbackNotifiesAndCapturesOnce() async throws {
        SentryCapture.resetForTesting()
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))
        let timerID = "timer-\(uuid.uuidString.lowercased())"
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .authorized
        alarms.operationError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)
        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)
        #expect(notifications.operations.contains(.schedule(identifier: notificationID, phase: .focus, duration: 60)))
        #expect(notifications.operations.contains(.schedule(identifier: notificationID, phase: .focus, duration: 30)))
        #expect(recorded.value.count == 1)
    }

    // AP79: restoreAccountDeletionCredentials distinguishes absent from throw.
    @Test @MainActor
    func restoreAccountDeletionCredentialsThrowReturnsFalseAndCaptures() async {
        SentryCapture.resetForTesting()
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        let store = RecordingTokenStore(tokens: nil, failures: [])
        let controller = AccountLifecycleController(
            api: APIClient(keychain: store),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore()
        )
        #expect(await controller.restoreAccountDeletionCredentials() == false)
        #expect(recorded.value.count == 0)
        store.replaceTokens(TokenPair(
            accessToken: "deletion-access", accessTokenExpiresAt: .distantFuture,
            refreshToken: "deletion-refresh", refreshTokenExpiresAt: .distantFuture
        ))
        store.setFailures([.load])
        #expect(await controller.restoreAccountDeletionCredentials() == false)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains("deletion-access"))
        #expect(!recorded.value[0].contains("deletion-refresh"))
    }

    // AP80: receipt throw captures, nil/mismatch stays silent.
    // createRoom clears the receipt and capture validates it, so the
    // corrupt receipt is staged via the persisted state file instead.
    @Test @MainActor
    func committedReceiptThrowReturnsFalseAndCaptures() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentryReceipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = Data(repeating: 5, count: 32)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let secrets = MemoryIrohRoomSecretStore()
        let fileURL = dir.appendingPathComponent("rooms.json")
        let setup = IrohRoomStore(fileURL: fileURL, secretStore: secrets)
        _ = try setup.createRoom(
            roomID: roomID, roomSecret: secret, name: "Secret Room",
            returnState: .fresh(), genesis: sentryEmptyGenesis()
        )
        let changedSource = Data("receipt-source-changed".utf8)
        var saved = try JSONDecoder.api.decode(IrohReplicationState.self, from: Data(contentsOf: fileURL))
        var roomState = saved.rooms[0].roomState
        roomState.irohLegacyTaskMigration = IrohLegacyTaskMigration(roomID: roomID, source: changedSource, state: roomState)
        saved.rooms[0].roomState = roomState
        try JSONEncoder.api.encode(saved).write(to: fileURL, options: .atomic)
        let store = IrohRoomStore(fileURL: fileURL, secretStore: secrets)
        let stored = try #require(store.activeRoomState)
        let api = APIClient(keychain: StaticTokenStore())
        let coordinator = CentralizedAccountSessionCoordinator(
            lifecycle: AccountLifecycleController(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: AccountSynchronization(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly),
            roomStore: store
        )
        let transition = AppStatePersistenceCoordinator.LoadTransition(
            replicationMode: .iroh, state: stored, removesLegacyTasksAfterProjection: false,
            shouldPersistAfterProjection: false, shouldReportInvalidLocalClock: false,
            snapshotLoadFailure: nil, legacyTaskSource: changedSource
        )
        coordinator.setLegacyMigrationForTesting(transition: transition, roomID: roomID)
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var c = recorded.value; c.append(error.localizedDescription); recorded.value = c
        }
        defer { SentryCapture.resetForTesting() }
        #expect(coordinator.containsCommittedLegacyRecords(stored, in: stored) == false)
        #expect(recorded.value.count == 1)
        #expect(!recorded.value[0].contains(roomID))
    }

    private func sentryStrippedTimerJSON(removing keys: [String]) throws -> Data {
        let data = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        let object = try JSONSerialization.jsonObject(with: data)
        var dict = try #require(object as? [String: Any])
        for key in keys { dict.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func sentryEmptyGenesis() -> IrohGenesis {
        IrohGenesis(canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
            autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0)
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
    private var ticketError: SentryRoomServiceError?

    func setStartError(_ error: SentryRoomServiceError?) {
        startError = error
    }

    func setTicketError(_ error: SentryRoomServiceError?) {
        ticketError = error
    }

    func start(_ context: IrohServiceContext) async throws -> String {
        startedContexts.append(context)
        if let startError { throw startError }
        return "endpoint-ticket"
    }

    func stop() async {}
    func currentEndpointTicket() async throws -> String {
        if let ticketError { throw ticketError }
        return "endpoint-ticket"
    }
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

private struct SentryTestKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { Data(repeating: 7, count: 32) }
    func save(_ secret: Data) throws {}
}
