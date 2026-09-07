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

    @Test
    func sentrySetupWithoutDSNReturnsWithoutCrashing() {
        SentrySetup.startIfConfigured()
    }
}
