import Foundation
import Testing
@testable import Pomodorough

@Suite("Account-switch cancel durability", .timeLimit(.minutes(1)))
struct AccountSwitchCancelDurabilityTests {
    @Test @MainActor
    func postCancelRetryAfterFirstWriteRefusal() async throws {
        try await AccountSwitchCancelFixture.run { fixture in
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
    }

    // Control by design, not a proof: the refused cancel leaves pending bytes
    // on disk, so a relaunch restores the pending fence on both sides of the
    // R51 fix. Kept as the envelope for postCancelRetryAfterFirstWriteRefusal.
    @Test @MainActor
    func relaunchEnvelopeAfterRefusedCancelRestoresPendingFence() async throws {
        try await AccountSwitchCancelFixture.run { fixture in
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
    }

    @Test @MainActor
    func committedReplayIsNoOp() async throws {
        try await AccountSwitchCancelFixture.run { fixture in
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
    }

    // Regression for the full-run host abort "Task created in a session that
    // has been invalidated", which Swift Testing attributed to
    // committedReplayIsNoOp. Cancellation detaches a logout obligation and
    // starts the revocation retry loop. The stub holds that revoke on the
    // scenario's revocation gate, which teardown opens only while it waits
    // for the obligations to drain, so the revoke is in flight when teardown
    // begins. Teardown must let it finish and drain the obligation before it
    // invalidates the session.
    @Test @MainActor
    func teardownDrainsHeldRevocationBeforeInvalidatingSession() async throws {
        let tornDown = try await AccountSwitchCancelFixture.run(revocation: .heldUntilDrained) { fixture in
            _ = try fixture.seedPendingSwitch()
            let model = try fixture.model()
            try await fixture.restoreSignedIn(model)
            await model.cancelAccountSwitch()
            try #require(await TestFixtures.waitForRequest(in: fixture.scenario, path: "/api/v1/auth/logout"))
            let pending: [LogoutRevocationObligation] = try fixture.tokens.load()
            try #require(pending.count == 1)
        }
        let leftover: [LogoutRevocationObligation] = try tornDown.tokens.load()
        // A teardown that invalidates first cancels the held revoke, which
        // keeps its obligation for a retry. Removing it ends the loop's next
        // pass on .empty instead of on the invalidated session, so such a
        // regression fails the expectations below instead of aborting the host.
        for obligation in leftover { try tornDown.tokens.remove(id: obligation.id) }
        #expect(leftover.isEmpty)
        let logoutEvents = TestFixtures.lifecycleEvents(for: tornDown.scenario).filter { $0.hasPrefix("logout ") }
        #expect(logoutEvents == ["logout response completed", "logout session invalidated"])
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

    // The os_log lines print DiagnosticPrivacy.publicSummary, which reads
    // diagnosticDescription rather than errorDescription. The Sentry scrub
    // drops that text, so the summary is the only place it shows. The
    // persist-failure tests below pin the other stage and outcome values.
    @Test
    func accountSwitchSummariesKeepStageOutcomeAndCounts() {
        let cancel = AccountSwitchCancelDiagnostics(
            stage: .credentials, outcome: .uncertain, quarantined: true, pendingOperations: 1
        )
        #expect(DiagnosticPrivacy.publicSummary(cancel)
            == "account-switch stage=cancel phase=credentials outcome=uncertain quarantined=true pending=1")
        let confirm = AccountSwitchConfirmDiagnostics(outcome: .uncertain, quarantined: true, pendingOperations: 2)
        #expect(DiagnosticPrivacy.publicSummary(confirm)
            == "account-switch stage=confirm outcome=uncertain quarantined=true pending=2")
    }
}

// R54-L09: account-switch persist failures carry the account boundary and a
// finite identity through the real SDK transport. Before the fix both sites
// sent application.failure with OtherError.
@Suite("R54-L09 account-switch boundary tags", .serialized, .timeLimit(.minutes(1)))
struct AccountSwitchBoundaryTagTests {
    @Test @MainActor
    func cancelPersistFailureKeepsAccountBoundary() async throws {
        try await AccountSwitchCancelFixture.run { fixture in
            _ = try fixture.seedPendingSwitch()
            let model = try fixture.model()
            try await fixture.restoreSignedIn(model)
            defer { SentryCapture.resetForTesting() }
            let captures = BoundaryCaptureLog()
            try fixture.permissions(0o500, at: fixture.directory)
            defer { try? fixture.permissions(0o700, at: fixture.directory) }
            await model.cancelAccountSwitch()
            #expect(model.pendingAccountSwitchUser != nil)
            let cancel = captures.errors(identity: "AccountSwitch.cancel")
            try #require(cancel.count == 1, "captures: \(captures.summary)")
            try expectTransportedBoundary(cancel[0], operation: "account.failure", identity: "AccountSwitch.cancel")
            // The recorded description is the text the site's os_log line prints:
            // both come from DiagnosticPrivacy.diagnostic.
            #expect(model.snapshotLoadFailure == nil)
            #expect(model.pendingChangeCount == 0)
            #expect(cancel[0].localizedDescription
                == "account-switch stage=cancel phase=persist outcome=failed quarantined=false pending=0")
        }
    }

    // Cached and pending users match, so the offline restore signs in as the
    // pending account and confirm reaches its durable write without a
    // network sign-in.
    @Test @MainActor
    func confirmPersistFailureKeepsAccountBoundary() async throws {
        try await AccountSwitchCancelFixture.run { fixture in
            var state = TestFixtures.syncContractState(includesPendingOperations: false)
            state.cachedUser = TestFixtures.user
            state.pendingAccountSwitchUser = TestFixtures.user
            _ = try fixture.seed(state: state)
            let model = try fixture.model()
            try await fixture.restoreSignedIn(model)
            try #require(model.user?.id == TestFixtures.user.id)
            defer { SentryCapture.resetForTesting() }
            let captures = BoundaryCaptureLog()
            try fixture.permissions(0o500, at: fixture.directory)
            defer { try? fixture.permissions(0o700, at: fixture.directory) }
            await model.confirmAccountSwitch()
            #expect(model.pendingAccountSwitchUser != nil)
            let confirm = captures.errors(identity: "AccountSwitch.confirm")
            try #require(confirm.count == 1, "captures: \(captures.summary)")
            try expectTransportedBoundary(confirm[0], operation: "account.failure", identity: "AccountSwitch.confirm")
            #expect(model.snapshotLoadFailure == nil)
            #expect(model.pendingChangeCount == 0)
            #expect(confirm[0].localizedDescription
                == "account-switch stage=confirm outcome=failed quarantined=false pending=0")
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
    let scenario: String
    let logout: LogoutDrainingSession
    var url: URL { directory.appendingPathComponent("workspace.json") }

    private init(revocation: LogoutRevocationStub) throws {
        scenario = revocation.scenario("apple-api-coverage-model-cancel-\(UUID().uuidString)")
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        logout = LogoutDrainingSession(scenario: scenario, obligations: tokens)
    }

    // Runs one test body with a fixture it owns and tears the fixture down on
    // every exit path. Account-switch cancellation starts a logout
    // revocation, so LogoutDrainingSession drains it before it invalidates
    // the session.
    @discardableResult
    static func run(
        revocation: LogoutRevocationStub = .immediate,
        _ operation: @MainActor (AccountSwitchCancelFixture) async throws -> Void
    ) async throws -> AccountSwitchCancelFixture {
        let fixture = try AccountSwitchCancelFixture(revocation: revocation)
        defer { fixture.removeStorage() }
        try await fixture.logout.run {
            try await operation(fixture)
        }
        return fixture
    }

    private func removeStorage() {
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
        logout.track(AppModel(
            api: APIClient(session: logout.session, keychain: tokens),
            defaults: defaults, durableLocalStore: store ?? AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarms, googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        ))
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
        logout.track(AppModel(
            api: APIClient(session: logout.session, keychain: EmptyTokenStore()),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        ))
    }
}
