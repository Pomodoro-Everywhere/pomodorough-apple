import Foundation
import Testing
@testable import Pomodorough

/// R52-AP03: deferred Watch settings carry the phone-owned workspace epoch
/// stamped by the production send planner. Sign-out, account confirmation,
/// room adoption, and deletion rotate the epoch; delivery after rotation is
/// rejected with a fixed bounded reason and a corrective snapshot instead
/// of mutating the new workspace. Legacy commands (no epoch) stay accepted
/// live but are rejected deferred.
@Suite("R52-AP03 deferred Watch settings workspace epoch", .serialized)
struct R52AP03WatchWorkspaceGenerationTests {
    @Test @MainActor
    func deferredSettingsAcrossSignOutRejected() async throws {
        let fixture = try R52AP03Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let model = try fixture.model()
        try await fixture.restoreSignedIn(model)
        let freshMinutes = model.durationMinutes(for: .focus)
        let queuedMinutes = freshMinutes == 37 ? 25 : 37
        let wire = try #require(fixture.queuedWireCommand(
            model, .setDuration(minutes: queuedMinutes, forPhaseRawValue: "focus")))
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        model.signOut()
        await fixture.waitForSignOut(model)
        try #require(!model.isWorking)
        #expect(model.durationMinutes(for: .focus) == freshMinutes)
        #expect(!model.applyWatchCommand(wire, isDeferred: true))
        #expect(model.durationMinutes(for: .focus) == freshMinutes)
        #expect(model.pendingDurationOperationCount == 0)
        #expect(!model.applyWatchCommand(wire))
        #expect(model.durationMinutes(for: .focus) == freshMinutes)
        #expect(recorded.value.contains("stale_workspace"))
        let reopened = try fixture.reopened()
        await reopened.restore()
        #expect(reopened.durationMinutes(for: .focus) == freshMinutes)
    }

    @Test @MainActor
    func sameWorkspaceDeferredWireRoundTripAccepted() throws {
        let fixture = try R52AP03Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let model = try fixture.model()
        try #require(model.snapshotLoadFailure == nil)
        let freshMinutes = model.durationMinutes(for: .focus)
        let queuedMinutes = freshMinutes == 37 ? 25 : 37
        let wire = try #require(fixture.queuedWireCommand(
            model, .setDuration(minutes: queuedMinutes, forPhaseRawValue: "focus")))
        #expect(model.applyWatchCommand(wire, isDeferred: true))
        #expect(model.durationMinutes(for: .focus) == queuedMinutes)
    }

    @Test @MainActor
    func legacyDeferredRejectedLiveAccepted() throws {
        let fixture = try R52AP03Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let model = try fixture.model()
        try #require(model.snapshotLoadFailure == nil)
        let freshMinutes = model.durationMinutes(for: .focus)
        let queuedMinutes = freshMinutes == 37 ? 25 : 37
        let legacy = try #require(fixture.wireRoundTrip(
            .setDuration(minutes: queuedMinutes, forPhaseRawValue: "focus")))
        #expect(legacy.workspaceGeneration == nil)
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        #expect(!model.applyWatchCommand(legacy, isDeferred: true))
        #expect(model.durationMinutes(for: .focus) == freshMinutes)
        #expect(recorded.value.contains("stale_workspace"))
        #expect(model.applyWatchCommand(legacy))
        #expect(model.durationMinutes(for: .focus) == queuedMinutes)
    }

    @Test @MainActor
    func restartKeepsEpochForSameWorkspaceRetry() throws {
        let fixture = try R52AP03Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let model = try fixture.model()
        try #require(model.snapshotLoadFailure == nil)
        let freshMinutes = model.durationMinutes(for: .focus)
        let queuedMinutes = freshMinutes == 37 ? 25 : 37
        let wire = try #require(fixture.queuedWireCommand(
            model, .setDuration(minutes: queuedMinutes, forPhaseRawValue: "focus")))
        let reopened = try fixture.reopened()
        #expect(reopened.applyWatchCommand(wire, isDeferred: true))
        #expect(reopened.durationMinutes(for: .focus) == queuedMinutes)
    }

    @Test @MainActor
    func roomAdoptRotatesEpoch() throws {
        let fixture = try R52AP03Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.seedAccount()
        let model = try fixture.model()
        try #require(model.snapshotLoadFailure == nil)
        let before = model.makeWatchSnapshot()
        let stale = try #require(fixture.queuedWireCommand(model, .selectPhase("long_break")))
        model.adoptRoomWorkspace(PersistedTimerState.fresh())
        let after = model.makeWatchSnapshot()
        #expect(after.workspaceGeneration != before.workspaceGeneration)
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        #expect(!model.applyWatchCommand(stale, isDeferred: true))
        #expect(recorded.value == ["stale_workspace"])
        #expect(model.selectedPhase == .focus)
        let retry = try #require(fixture.queuedWireCommand(model, .selectPhase("long_break")))
        #expect(model.applyWatchCommand(retry, isDeferred: true))
        #expect(model.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func accountSwitchConfirmRotatesEpoch() async throws {
        let scenario = "apple-api-coverage-model-sign-in"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.R52AP03.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        let freshMinutes = model.durationMinutes(for: .focus)
        let stale = try #require(R52AP03Fixture.queuedWireCommand(
            model, .setDuration(minutes: 37, forPhaseRawValue: "focus")))
        model.signIn()
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        await model.confirmAccountSwitch()
        let persisted = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: try #require(defaults.data(forKey: "timer-state-v2")))
        try #require(persisted.cachedUser == TestFixtures.user)
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        #expect(!model.applyWatchCommand(stale, isDeferred: true))
        #expect(recorded.value.contains("stale_workspace"))
        #expect(model.durationMinutes(for: .focus) == freshMinutes)
    }

    @Test
    func sendPlannerBindsSettingsEpoch() throws {
        let epoch = UUID()
        var snapshot = R52AP03Fixture.snapshot()
        snapshot.workspaceGeneration = epoch
        let command = WatchTimerCommand.setDuration(minutes: 37, forPhaseRawValue: "focus")
        guard case .queued(let queued) = planWatchCommandSend(
            command, snapshot: snapshot, isActivated: true, isReachable: false) else {
            Issue.record("settings queue while unreachable")
            return
        }
        #expect(queued.workspaceGeneration == epoch)
        guard case .live(let live) = planWatchCommandSend(
            command, snapshot: snapshot, isActivated: true, isReachable: true) else {
            Issue.record("settings go live while reachable")
            return
        }
        #expect(live.workspaceGeneration == epoch)
        let legacy = R52AP03Fixture.snapshot()
        #expect(legacy.workspaceGeneration == nil)
        guard case .queued(let legacyQueued) = planWatchCommandSend(
            command, snapshot: legacy, isActivated: true, isReachable: false) else {
            Issue.record("legacy settings queue while unreachable")
            return
        }
        #expect(legacyQueued.workspaceGeneration == nil)
        #expect(planWatchCommandSend(
            .start(), snapshot: snapshot, isActivated: true, isReachable: false)
            == .fail(.startRequiresConnection))
    }

    @Test
    func staleWorkspaceDiagnosticStaysFixed() {
        #expect(WatchStaleWorkspaceError().localizedDescription == "stale_workspace")
    }
}

@MainActor
private final class R52AP03Fixture {
    let suiteName = "R52AP03.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R52AP03-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "r52-ap03-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "r52-ap03-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let identity = RecordingGoogleIdentityProvider()
    let alarms = RecordingAlarmScheduler()
    let scenario = "apple-api-coverage-model-local-signout-\(UUID().uuidString)"
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

    func seedAccount() throws -> PersistedTimerState {
        let state = TestFixtures.syncContractState(includesPendingOperations: false)
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        return state
    }

    func model() throws -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: tokens, logoutRevocationStore: nil),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarms, googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func reopened() throws -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: tokens),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: url),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(), googleIdentityProvider: identity,
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

    func queuedWireCommand(_ model: AppModel, _ command: WatchTimerCommand) -> WatchTimerCommand? {
        let planned = planWatchCommandSend(
            command, snapshot: model.makeWatchSnapshot(),
            isActivated: true, isReachable: false)
        guard case .queued(let queued) = planned else { return nil }
        return try? wireRoundTrip(queued)
    }

    func wireRoundTrip(_ command: WatchTimerCommand) -> WatchTimerCommand? {
        guard let data = try? JSONEncoder().encode(command) else { return nil }
        return try? JSONDecoder().decode(WatchTimerCommand.self, from: data)
    }

    static func queuedWireCommand(_ model: AppModel, _ command: WatchTimerCommand) -> WatchTimerCommand? {
        let planned = planWatchCommandSend(
            command, snapshot: model.makeWatchSnapshot(),
            isActivated: true, isReachable: false)
        guard case .queued(let queued) = planned else { return nil }
        guard let data = try? JSONEncoder().encode(queued) else { return nil }
        return try? JSONDecoder().decode(WatchTimerCommand.self, from: data)
    }

    nonisolated static func snapshot() -> WatchTimerSnapshot {
        WatchTimerSnapshot(
            phase: "focus", status: "idle", timerId: nil,
            plannedDurationMs: 1_500_000, elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor, selectedPhase: "focus",
            focusDurationMs: 1_500_000, shortBreakDurationMs: 300_000,
            longBreakDurationMs: 900_000, updatedAt: TestFixtures.anchor
        )
    }
}
