import Foundation
import Testing
@testable import Pomodorough

@Suite("Sign-out durability")
struct SignOutDurabilityTests {
    @Test @MainActor
    func firstWriteRefusalPreservesAccountFence() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedAccount()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        let beforeBytes = try fixture.savedBytes()
        let alarmsBefore = fixture.alarms.operations.count
        try fixture.permissions(0o500, at: fixture.directory)
        defer { try? fixture.permissions(0o700, at: fixture.directory) }
        model.signOut()
        await fixture.waitForSignOut(model)
        await model.waitForAlarmOperations()
        #expect(try fixture.savedBytes() == beforeBytes)
        #expect(try fixture.savedState().cachedUser?.id == seed.cachedUser?.id)
        #expect(model.isSignedIn)
        #expect(model.tasks.count == seed.tasks.count)
        #expect(fixture.tokens.tokens != nil)
        #expect(fixture.identity.signOutCount == 0)
        #expect(fixture.alarms.operations.count == alarmsBefore)
        #expect(model.errorMessage != nil)
        #expect(model.snapshotLoadFailure == nil)
        #expect(fixture.errorHidesAccount(seed: seed, model: model))
    }

    @Test @MainActor
    func writableRetryAfterRefusalClearsWorkspace() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedAccount()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        try fixture.permissions(0o500, at: fixture.directory)
        model.signOut()
        await fixture.waitForSignOut(model)
        #expect(model.isSignedIn)
        try fixture.permissions(0o700, at: fixture.directory)
        model.signOut()
        await fixture.waitForSignOut(model)
        await model.waitForAlarmOperations()
        try fixture.expectCleanSignOut(model, seed: seed)
    }

    @Test @MainActor
    func replacementUncertaintyQuarantinesMutations() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let flag = fixture.directory.appendingPathComponent("signout-replacement-fails")
        let store = AtomicDurableFileStore(fileURL: fixture.url, afterReplacement: {
            if FileManager.default.fileExists(atPath: flag.path) { throw POSIXError(.EIO) }
        })
        let model = try fixture.model(store: store)
        try await fixture.restoreSignedIn(model)
        try Data().write(to: flag)
        model.signOut()
        await fixture.waitForSignOut(model)
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(fixture.tokens.tokens != nil)
        #expect(fixture.identity.signOutCount == 0)
        #expect(model.errorMessage != nil)
        try FileManager.default.removeItem(at: flag)
        await model.retrySnapshotLoad()
        #expect(model.snapshotLoadFailure == nil)
        #expect(try fixture.savedState().cachedUser == nil)
        #expect(try fixture.savedState().tasks.isEmpty)
    }

    @Test @MainActor
    func writableSignOutClearsBytesStateCredentialsAndAlarms() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedAccount()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        let timerID = try #require(model.canonicalTimer?.id)
        model.signOut()
        await fixture.waitForSignOut(model)
        await model.waitForAlarmOperations()
        try fixture.expectCleanSignOut(model, seed: seed)
        #expect(fixture.alarms.operations.contains(.cancel(timerID: timerID)))
    }

    @Test @MainActor
    func relaunchWithoutCredentialsExposesNothingAfterSuccess() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedAccount()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        model.signOut()
        await fixture.waitForSignOut(model)
        try fixture.expectCleanSignOut(model, seed: seed)
        let relaunched = try fixture.relaunchedWithoutCredentials()
        await relaunched.restore()
        #expect(relaunched.sessionState == .localOnly)
        #expect(relaunched.tasks.isEmpty)
        #expect(relaunched.history.isEmpty)
        #expect(try fixture.savedState().cachedUser == nil)
        #expect(try fixture.savedState().tasks.isEmpty)
    }

    @Test @MainActor
    func signOutDuringSyncClearsWithoutResurrection() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .centralizedWithPendingSync)
        defer { fixture.cleanup() }
        _ = try fixture.seed(state: TestFixtures.syncContractState(includesPendingOperations: false))
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        let added = await model.addTask("Sync race task")
        try #require(added)
        #expect(model.pendingChangeCount > 0)
        model.signOut()
        await fixture.waitForSignOut(model)
        await model.waitForAlarmOperations()
        #expect(model.sessionState == .localOnly)
        #expect(model.tasks.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(fixture.tokens.tokens == nil)
        #expect(try fixture.savedState().cachedUser == nil)
        #expect(try fixture.savedState().pendingTaskOperations.isEmpty)
    }

    @Test @MainActor
    func bootstrapPreservingSignOutKeepsResolution() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedBootstrap()
        let model = try fixture.model()
        await model.restore()
        model.signOut()
        await fixture.waitForSignOut(model)
        #expect(model.sessionState == .localOnly)
        #expect(try fixture.savedState().bootstrapUser?.id == seed.bootstrapUser?.id)
        #expect(try fixture.savedState().cachedUser == nil)
        #expect(model.historyResolutionState == .retryable(nil))
        #expect(fixture.identity.signOutCount == 1)
        #expect(!fixture.alarms.operations.contains(where: { $0.isCancel }))
    }

    // R51 sweep DARK branch: AppModel.restoreAccountSnapshotAfterDetachFailure
    // persist-failure path. Detach fails (revocation store refuses append),
    // then the follow-up rewrite fails (second post-restore write throws),
    // so the flow reports stage=.snapshot AND stage=.credentials, quarantines,
    // and keeps the never-detached credentials. Precommit success writes the
    // signed-out bytes but leaves memory for finish publication, so the
    // rewrite persists the still-signed-in timerState and reverts the disk;
    // the fence (sessionState) never leaves signed-in on this path.
    @Test @MainActor
    func detachFailureFollowedByRewriteFailureQuarantinesWithBothReports() async throws {
        let fixture = try SignOutDurabilityFixture(mode: .offline)
        defer { fixture.cleanup() }
        let seed = try fixture.seedAccount()
        let gate = SecondWriteGate()
        let store = AtomicDurableFileStore(fileURL: fixture.url, afterReplacement: { try gate.hook() })
        let model = try fixture.model(store: store, revocationStore: FailingDetachStore())
        try await fixture.restoreSignedIn(model)
        gate.armFailingSecondWrite()
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        model.signOut()
        await fixture.waitForSignOut(model)
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.isSignedIn)
        #expect(model.tasks.map(\.title) == seed.tasks.map(\.title))
        #expect(fixture.tokens.tokens != nil)
        #expect(fixture.identity.signOutCount == 0)
        #expect(model.errorMessage != nil)
        #expect(try fixture.savedState().cachedUser?.id == seed.cachedUser?.id)
        #expect(recorded.value.contains(where: { $0.contains("sign-out stage=snapshot") }))
        #expect(recorded.value.contains(where: { $0.contains("sign-out stage=credentials") }))
        #expect(recorded.value.allSatisfy { !$0.contains("signout-access") })
    }

    // Lifecycle guard behind AppModel.finishSignedOutPublication nil-transition:
    // the AppModel call site passes isWorking:false unconditionally, so the
    // else branch stays defensive. This pins the guard itself.
    @Test @MainActor
    func signOutBeginNilGuardRequiresIdle() {
        let lifecycle = AccountLifecycleController(
            api: APIClient(keychain: RecordingTokenStore()),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        #expect(lifecycle.beginSignOut(isWorking: true, preservesBootstrapResolution: false, pendingStrategy: nil) == nil)
        #expect(lifecycle.beginSignOut(isWorking: false, preservesBootstrapResolution: false, pendingStrategy: nil) != nil)
    }

    @Test @MainActor
    func signOutDiagnosticsStayBounded() {
        let diagnostic = SignOutDiagnostics(
            stage: .snapshot, outcome: .failed, quarantined: false, pendingOperations: 3
        )
        let text = diagnostic.localizedDescription
        #expect(diagnostic.key == "sign-out-snapshot-failed")
        #expect(text.contains("stage=snapshot"))
        #expect(text.contains("outcome=failed"))
        #expect(!text.contains("Local canonical task"))
        #expect(!text.contains("user-duration-sync"))
        #expect(!text.contains("csrf"))
    }
}

@MainActor
private final class SignOutDurabilityFixture {
    enum Mode { case offline, centralizedWithPendingSync }

    let suiteName = "SignOutDurability.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SignOutDurability-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "signout-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "signout-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let identity = RecordingGoogleIdentityProvider()
    let alarms = RecordingAlarmScheduler()
    let scenario = "apple-api-coverage-model-local-signout-\(UUID().uuidString)"
    var session: URLSession!
    var url: URL { directory.appendingPathComponent("workspace.json") }

    init(mode: Mode) throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        if mode == .centralizedWithPendingSync {
            defaults.set(ReplicationMode.centralized.rawValue, forKey: "replication-mode-v1")
        }
        session = TestFixtures.session(for: scenario)
    }

    func cleanup() {
        TestFixtures.releaseScenario(scenario)
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seedAccount() throws -> PersistedTimerState {
        var state = TestFixtures.syncContractState(includesPendingOperations: false)
        if defaults.string(forKey: "replication-mode-v1") == ReplicationMode.centralized.rawValue {
            state = TestFixtures.syncContractState(includesPendingOperations: true)
        }
        return try seed(state: state)
    }

    func seedBootstrap() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        return try seed(state: state)
    }

    func seed(state: PersistedTimerState) throws -> PersistedTimerState {
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
        return state
    }

    func model(store: AtomicDurableFileStore? = nil, revocationStore: (any LogoutRevocationStoring)? = nil) throws -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: tokens, logoutRevocationStore: revocationStore),
            defaults: defaults, durableLocalStore: store ?? AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarms, googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func restoreSignedIn(_ model: AppModel) async throws {
        await model.restore()
        try #require(model.isSignedIn)
    }

    func waitForSignOut(_ model: AppModel) async {
        for _ in 0..<200 where model.isWorking {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func savedBytes() throws -> Data { try Data(contentsOf: url) }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: savedBytes())
    }

    func permissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func expectCleanSignOut(_ model: AppModel, seed: PersistedTimerState) throws {
        #expect(!model.isWorking)
        #expect(model.sessionState == .localOnly)
        #expect(model.tasks.isEmpty)
        #expect(model.history.isEmpty)
        #expect(tokens.tokens == nil)
        #expect(identity.signOutCount == 1)
        #expect(model.errorMessage == nil)
        let saved = try savedState()
        #expect(saved.cachedUser == nil)
        #expect(saved.tasks.isEmpty)
        #expect(saved.history.isEmpty)
        #expect(errorHidesAccount(seed: seed, model: model))
    }

    func errorHidesAccount(seed: PersistedTimerState, model: AppModel) -> Bool {
        let message = model.errorMessage ?? model.conflictMessage ?? ""
        let titles = seed.tasks.map(\.title)
        return !titles.contains(where: { !$0.isEmpty && message.contains($0) })
            && !message.contains("user-duration-sync")
    }

    func relaunchedWithoutCredentials() throws -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: EmptyTokenStore()),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }
}

private extension RecordedAlarmOperation {
    var isCancel: Bool {
        if case .cancel = self { return true }
        return false
    }
}

// Refuses the detach append so AccountLifecycleController.logout fails.
// Lets the test drive detach-failure paths without touching the server.
private struct FailingDetachStore: LogoutRevocationStoring, Sendable {
    struct DetachFailure: Error {}
    func load() throws -> [LogoutRevocationObligation] { [] }
    func append(_ obligation: LogoutRevocationObligation) throws { throw DetachFailure() }
    func replace(_ obligation: LogoutRevocationObligation) throws {}
    func remove(id: UUID) throws {}
}

// Fails the second post-arm durable write: the first (precommit) succeeds,
// the follow-up (restore rewrite) throws EIO after replacement, which the
// coordinator reconciles into durability-uncertain quarantine.
private final class SecondWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var failFromWrite: Int?
    func armFailingSecondWrite() {
        lock.withLock { failFromWrite = writes + 2 }
    }
    var writeCount: Int { lock.withLock { writes } }
    func hook() throws {
        let (count, gate) = lock.withLock { writes += 1; return (writes, failFromWrite) }
        if let gate, count >= gate { throw POSIXError(.EIO) }
    }
}
