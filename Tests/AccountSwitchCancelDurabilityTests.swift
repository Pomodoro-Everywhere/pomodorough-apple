import Foundation
import Testing
@testable import Pomodorough

@Suite("Account-switch cancel durability")
struct AccountSwitchCancelDurabilityTests {
    @Test @MainActor
    func postCancelRetryAfterFirstWriteRefusal() async throws {
        let fixture = try AccountSwitchCancelFixture()
        defer { fixture.cleanup() }
        let seed = try fixture.seedPendingSwitch()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        let beforeBytes = try fixture.savedBytes()
        try fixture.permissions(0o500, at: fixture.directory)
        defer { try? fixture.permissions(0o700, at: fixture.directory) }
        await model.cancelAccountSwitch()
        #expect(try fixture.savedBytes() == beforeBytes)
        #expect(model.pendingAccountSwitchUser?.id == TestFixtures.user.id)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.isSignedIn)
        #expect(model.tasks.map(\.title) == seed.tasks.map(\.title))
        #expect(Set(seed.history.map(\.id)).isSubset(of: Set(model.history.map(\.id))))
        #expect(model.errorMessage != nil)
        #expect(model.snapshotLoadFailure == nil)
        #expect(fixture.errorHidesAccount(seed: seed, model: model))
        try fixture.permissions(0o700, at: fixture.directory)
        await model.cancelAccountSwitch()
        try fixture.expectCleanCancel(model, seed: seed)
    }

    // Control by design, not a proof: the refused cancel leaves pending bytes
    // on disk, so a relaunch restores the pending fence on both sides of the
    // R51 fix. Kept as the envelope for postCancelRetryAfterFirstWriteRefusal.
    @Test @MainActor
    func relaunchEnvelopeAfterRefusedCancelRestoresPendingFence() async throws {
        let fixture = try AccountSwitchCancelFixture()
        defer { fixture.cleanup() }
        let seed = try fixture.seedPendingSwitch()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        try fixture.permissions(0o500, at: fixture.directory)
        defer { try? fixture.permissions(0o700, at: fixture.directory) }
        await model.cancelAccountSwitch()
        #expect(model.pendingAccountSwitchUser != nil)
        let relaunched = try fixture.relaunchedWithoutCredentials()
        await relaunched.restore()
        #expect(relaunched.pendingAccountSwitchUser?.id == TestFixtures.user.id)
        #expect(relaunched.isWorkspaceMutationBlocked)
        #expect(relaunched.tasks.map(\.title) == seed.tasks.map(\.title))
        #expect(!(await relaunched.addTask("Blocked after refused cancel")))
        #expect(fixture.errorHidesAccount(seed: seed, model: model))
    }

    @Test @MainActor
    func committedReplayIsNoOp() async throws {
        let fixture = try AccountSwitchCancelFixture()
        defer { fixture.cleanup() }
        let seed = try fixture.seedPendingSwitch()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        await model.cancelAccountSwitch()
        try fixture.expectCleanCancel(model, seed: seed)
        let beforeBytes = try fixture.savedBytes()
        let signOuts = fixture.identity.signOutCount
        await model.cancelAccountSwitch()
        #expect(try fixture.savedBytes() == beforeBytes)
        #expect(model.sessionState == .localOnly)
        #expect(model.pendingAccountSwitchUser == nil)
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(model.errorMessage == nil)
        #expect(fixture.identity.signOutCount == signOuts)
    }

    // Lifecycle guard behind AppModel.cancelAccountSwitch nil-transition:
    // the AppModel call site passes hasPendingAccountSwitch:true,
    // isWorking:false unconditionally, so the else branch stays defensive
    // (silent return, no report by design). This pins the guard itself.
    @Test @MainActor
    func cancelBeginNilGuardRequiresPendingAndIdle() {
        let lifecycle = AccountLifecycleController(
            api: APIClient(keychain: RecordingTokenStore()),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        #expect(lifecycle.beginAccountSwitchCancellation(hasPendingAccountSwitch: false, isWorking: false) == nil)
        #expect(lifecycle.beginAccountSwitchCancellation(hasPendingAccountSwitch: true, isWorking: true) == nil)
        #expect(lifecycle.beginAccountSwitchCancellation(hasPendingAccountSwitch: true, isWorking: false) != nil)
    }

    @Test @MainActor
    func cancelDiagnosticsStayBoundedAndIsolated() {
        let failed = AccountSwitchCancelDiagnostics(
            stage: .persist, outcome: .failed, quarantined: false, pendingOperations: 3
        )
        #expect(failed.key == "account-switch-cancel-persist-failed")
        #expect(failed.localizedDescription.contains("stage=cancel"))
        #expect(failed.localizedDescription.contains("phase=persist"))
        #expect(failed.localizedDescription.contains("outcome=failed"))
        let uncertain = AccountSwitchCancelDiagnostics(
            stage: .credentials, outcome: .uncertain, quarantined: true, pendingOperations: 1
        )
        #expect(uncertain.key == "account-switch-cancel-credentials-uncertain")
        for diagnostic in [failed, uncertain] {
            let text = diagnostic.localizedDescription
            #expect(!text.contains("Local canonical task"))
            #expect(!text.contains("user-duration-sync"))
            #expect(!text.contains("csrf"))
            #expect(!text.contains("old-user"))
        }
    }
}

@MainActor
private final class AccountSwitchCancelFixture {
    let suiteName = "AccountSwitchCancel.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AccountSwitchCancel-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "cancel-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "cancel-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let identity = RecordingGoogleIdentityProvider()
    let alarms = RecordingAlarmScheduler()
    let scenario = "apple-api-coverage-model-cancel-\(UUID().uuidString)"
    var session: URLSession!
    var url: URL { directory.appendingPathComponent("workspace.json") }

    init() throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        session = TestFixtures.session(for: scenario)
    }

    func cleanup() {
        TestFixtures.releaseScenario(scenario)
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seedPendingSwitch() throws -> PersistedTimerState {
        var state = TestFixtures.syncContractState(includesPendingOperations: false)
        state.cachedUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        state.pendingAccountSwitchUser = TestFixtures.user
        return try seed(state: state)
    }

    func seed(state: PersistedTimerState) throws -> PersistedTimerState {
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
        return state
    }

    func model(store: AtomicDurableFileStore? = nil) throws -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: tokens),
            defaults: defaults, durableLocalStore: store ?? AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarms, googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func restoreSignedIn(_ model: AppModel) async throws {
        await model.restore()
        try #require(model.isSignedIn)
        try #require(model.pendingAccountSwitchUser != nil)
        try #require(model.isWorkspaceMutationBlocked)
    }

    func savedBytes() throws -> Data { try Data(contentsOf: url) }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: savedBytes())
    }

    func permissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func expectCleanCancel(_ model: AppModel, seed: PersistedTimerState) throws {
        #expect(!model.isWorking)
        #expect(model.sessionState == .localOnly)
        #expect(model.pendingAccountSwitchUser == nil)
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(model.tasks.map(\.title) == seed.tasks.map(\.title))
        #expect(Set(seed.history.map(\.id)).isSubset(of: Set(model.history.map(\.id))))
        #expect(model.errorMessage == nil)
        #expect(tokens.tokens == nil)
        #expect(identity.signOutCount == 1)
        #expect(try savedState().pendingAccountSwitchUser == nil)
        #expect(errorHidesAccount(seed: seed, model: model))
    }

    func errorHidesAccount(seed: PersistedTimerState, model: AppModel) -> Bool {
        let message = model.errorMessage ?? model.conflictMessage ?? ""
        let titles = seed.tasks.map(\.title)
        return !titles.contains(where: { !$0.isEmpty && message.contains($0) })
            && !message.contains("user-duration-sync")
            && !message.contains("old-user")
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
