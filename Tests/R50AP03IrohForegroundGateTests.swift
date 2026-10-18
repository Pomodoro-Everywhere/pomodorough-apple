import Foundation
import Testing
@testable import Pomodorough

// R50-AP03: Iroh foreground refresh releases the completion gate only
// on explicit backend-owner room-fenced success. Failed or stale
// refreshes stay fail-closed. Recovery commits exactly one history
// entry with correct generated-break dependencies.

private enum R50AP03ServiceError: Error {
    case endpointUnavailable
}

private actor R50AP03RoomService: RoomReplicationServing {
    var startError: R50AP03ServiceError?
    var syncResult = true
    var started = 0
    var synced = 0
    var suspendStart = false
    var startContinuations: [CheckedContinuation<Void, Never>] = []

    func start(_ context: IrohServiceContext) async throws -> String {
        started += 1
        if suspendStart {
            await withCheckedContinuation { c in startContinuations.append(c) }
        }
        if let startError { throw startError }
        return "endpoint-ticket"
    }

    func stop() async {}
    func currentEndpointTicket() async throws -> String { "endpoint-ticket" }
    func syncNow() async { synced += 1 }
    func foregroundSync() async -> Bool {
        synced += 1
        return syncResult
    }
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}

@MainActor
private final class R50AP03Clock {
    let anchor = Date(timeIntervalSince1970: 1_784_620_800)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

@MainActor
private final class R50AP03Sleeper {
    private var continuations: [CheckedContinuation<Void, any Error>?] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { c in continuations.append(c) }
    }
    func releaseAll() {
        for i in continuations.indices { continuations[i]?.resume(); continuations[i] = nil }
    }
}

@MainActor
private struct R50AP03Fixture {
    let suite: String
    let defaults: UserDefaults
    let directory: URL
    let clock = R50AP03Clock()
    let sleeper = R50AP03Sleeper()
    let roomStore: IrohRoomStore
    let service: R50AP03RoomService

    init() throws {
        suite = "PomodoroughTests.R50AP03.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let clock = clock
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"),
            secretStore: MemoryIrohRoomSecretStore(),
            now: { clock.now }
        )
        service = R50AP03RoomService()
    }

    func seedRunningFocus() throws {
        var base = PersistedTimerState.fresh()
        base.autoStartBreaks = true
        let timer = CanonicalTimer(
            id: "iroh-ap03-focus", taskId: nil, phase: .focus,
            status: .running, plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0, anchorAt: clock.anchor,
            startedByDeviceId: base.deviceId,
            lastIntent: TimerIntent(
                type: .start, commandId: "iroh-ap03-start",
                occurredAt: clock.anchor, deviceId: base.deviceId
            )
        )
        let secret = Data(0...31)
        _ = try roomStore.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret,
            name: nil, returnState: base,
            genesis: IrohGenesis(
                canonicalTimer: timer, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: true,
                hlcWallMs: 0, hlcCounter: 0
            ),
            now: clock.anchor
        )
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
    }

    func makeModel() -> AppModel {
        let clock = clock
        let sleeper = sleeper
        let service = service
        return AppModel(
            api: APIClient(
                session: TestFixtures.session(for: suite),
                keychain: StaticTokenStore()
            ),
            defaults: defaults,
            roomStore: roomStore,
            roomServiceFactory: { _ in service },
            alarmScheduler: RecordingAlarmScheduler(),
            completionScheduler: TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) }),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { clock.now },
            uptime: { clock.elapsed }
        )
    }

    func cleanUp() {
        sleeper.releaseAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("R50-AP03 Iroh foreground gate")
struct R50AP03IrohForegroundGateTests {
    @Test @MainActor
    func noPeerSuccessReleasesGate() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        let model = fixture.makeModel()
        #expect(model.replicationMode == .iroh)
        model.setSceneActive(false)
        #expect(model.testForegroundSyncPending == true)
        #expect(model.finish() == false)
        #expect(model.history.isEmpty)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        let started = await fixture.service.started
        let synced = await fixture.service.synced
        #expect(started >= 1)
        #expect(synced >= 1)
    }

    @Test @MainActor
    func failedStartRetainsGate() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        await fixture.service.setStartError(.endpointUnavailable)
        let model = fixture.makeModel()
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == true)
        #expect(model.finish() == false)
        #expect(model.history.isEmpty)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func failedSyncRetainsGate() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        await fixture.service.setSyncResult(false)
        let model = fixture.makeModel()
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == true)
        #expect(model.finish() == false)
        #expect(model.history.isEmpty)
        let synced = await fixture.service.synced
        #expect(synced == 1)
    }

    @Test @MainActor
    func modeSwitchBeforeRefreshSkipsIrohPath() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        let model = fixture.makeModel()
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        await model.setReplicationMode(.offline)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        let synced = await fixture.service.synced
        let started = await fixture.service.started
        #expect(synced == 0)
        #expect(started == 0)
    }

    @Test @MainActor
    func repeatRefreshManualFinishCommitsOnce() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        let focusID = try #require(fixture.roomStore.activeRoomState?.canonicalTimer?.id)
        let model = fixture.makeModel()
        model.setSceneActive(false)
        fixture.clock.elapsed = 30
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        let synced = await fixture.service.synced
        #expect(synced == 2)
        fixture.clock.elapsed = 90
        #expect(model.finish(at: fixture.clock.now) == true)
        #expect(model.completedFocusCount == 1)
        #expect(model.history.count == 1)
        let entry = try #require(model.history.first)
        #expect(entry.phase == .focus)
        #expect(entry.status == "completed")
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.id != focusID)
        #expect(fixture.roomStore.activeRoomState?.pendingTimerDependencies.isEmpty == true)
        #expect(model.history.count == 1)
    }

    @Test @MainActor
    func autoFinishAfterRecoveryCommitsOnce() async throws {
        let fixture = try R50AP03Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedRunningFocus()
        let focusID = try #require(fixture.roomStore.activeRoomState?.canonicalTimer?.id)
        let model = fixture.makeModel()
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        model.completeIfNeeded(timerID: focusID, at: fixture.clock.now)
        await model.waitForAlarmOperations()
        #expect(model.completedFocusCount == 1)
        #expect(model.history.count == 1)
        let entry = try #require(model.history.first)
        #expect(entry.phase == .focus)
        #expect(entry.status == "completed")
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(fixture.roomStore.activeRoomState?.pendingTimerDependencies.isEmpty == true)
        model.completeIfNeeded(timerID: focusID, at: fixture.clock.now)
        #expect(model.history.count == 1)
    }

    @Test @MainActor
    func staleRoomReplacementReturnsNone() async throws {
        let store = IrohRoomStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("R50AP03-stale-\(UUID().uuidString)/rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let secretA = Data(0...31)
        _ = try store.createRoom(
            roomID: IrohProtocolV1.roomID(for: secretA), roomSecret: secretA,
            name: nil, returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: false,
                hlcWallMs: 0, hlcCounter: 0
            )
        )
        let service = R50AP03RoomService()
        let state = LockedTestValue(RoomReplicationCentralizedState(
            sessionGeneration: 7, isSignedIn: false,
            isWorkspaceMutationBlocked: false, isSessionVerified: true,
            localRevision: 0, isSyncing: false,
            isTimerActive: false, isHistoryResolutionBlocking: false
        ))
        let workspace = LockedTestValue(RoomReplicationWorkspaceSnapshot(
            state: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: false,
                hlcWallMs: 0, hlcCounter: 0
            )
        ))
        let controller = RoomReplicationController(
            mode: .iroh,
            dependencies: .init(
                roomStore: store, retryDelay: .seconds(5),
                centralizedState: { state.value },
                workspaceSnapshot: { workspace.value },
                revisionEvents: { AsyncThrowingStream { $0.finish() } },
                sleep: { _ in throw CancellationError() },
                secureRandomBytes: { Data(repeating: 0, count: $0) },
                encodeInvite: { _, _, _, _ in "unused" },
                makeService: { _ in service }
            ),
            eventHandler: { _ in }, operationHandler: { _ in }
        )
        controller.setSceneActive(true, environment: RoomReplicationEnvironment(
            deviceID: "device", displayName: nil, platform: "macos"
        ))
        for _ in 0..<200 {
            if await service.started != 0 { break }
            await Task.yield()
        }
        #expect(await service.started != 0)
        await service.setSuspendStart(true)
        let baseline = await service.started
        let env = RoomReplicationEnvironment(deviceID: "device", displayName: nil, platform: "macos")
        let refresh = Task { await controller.refreshAfterForeground(environment: env) }
        for _ in 0..<200 {
            if await service.started != baseline { break }
            await Task.yield()
        }
        #expect(await service.started != baseline)
        let secretB = Data(32...63)
        _ = try store.createRoom(
            roomID: IrohProtocolV1.roomID(for: secretB), roomSecret: secretB,
            name: nil, returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: false,
                hlcWallMs: 0, hlcCounter: 0
            )
        )
        await service.releaseStart()
        let action = await refresh.value
        #expect(action == .none)
    }
}

// R50-AP04: foregroundSync false stays fail-closed (.none) with bounded
// count-only diagnostics. Other quiet .none branches (offline mode,
// unsigned-in, no snapshot/conflict, start failure covered at its own
// frame, stale re-check) stay quiet by design.
@Suite("R50-AP04 Iroh foreground sync-false diagnostics", .serialized)
struct R50AP04IrohForegroundSyncDiagnosticsTests {
    @MainActor
    private func makeController(
        service: R50AP03RoomService
    ) throws -> (RoomReplicationController, IrohRoomStore, RoomReplicationEnvironment) {
        let store = IrohRoomStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("R50AP04-sync-\(UUID().uuidString)/rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let secret = Data(0...31)
        _ = try store.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret,
            name: nil, returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: false,
                hlcWallMs: 0, hlcCounter: 0
            )
        )
        let state = LockedTestValue(RoomReplicationCentralizedState(
            sessionGeneration: 7, isSignedIn: false,
            isWorkspaceMutationBlocked: false, isSessionVerified: true,
            localRevision: 0, isSyncing: false,
            isTimerActive: false, isHistoryResolutionBlocking: false
        ))
        let workspace = LockedTestValue(RoomReplicationWorkspaceSnapshot(
            state: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: false,
                hlcWallMs: 0, hlcCounter: 0
            )
        ))
        let controller = RoomReplicationController(
            mode: .iroh,
            dependencies: .init(
                roomStore: store, retryDelay: .seconds(5),
                centralizedState: { state.value },
                workspaceSnapshot: { workspace.value },
                revisionEvents: { AsyncThrowingStream { $0.finish() } },
                sleep: { _ in throw CancellationError() },
                secureRandomBytes: { Data(repeating: 0, count: $0) },
                encodeInvite: { _, _, _, _ in "unused" },
                makeService: { _ in service }
            ),
            eventHandler: { _ in }, operationHandler: { _ in }
        )
        let env = RoomReplicationEnvironment(deviceID: "device", displayName: nil, platform: "macos")
        // iOS activeContext requires an active scene; without this the
        // controller returns .none before foregroundSync, so no
        // sync-false diagnostic is captured. Same pattern as the
        // AP03 stale-room test above.
        controller.setSceneActive(true, environment: env)
        return (controller, store, env)
    }

    private func record() -> LockedTestValue<[String]> {
        SentryCapture.resetForTesting()
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        return recorded
    }

    @Test @MainActor
    func syncFalseReturnsNoneWithCountOnlyCapture() async throws {
        let recorded = record()
        defer { SentryCapture.resetForTesting() }
        let service = R50AP03RoomService()
        await service.setSyncResult(false)
        let (controller, store, env) = try makeController(service: service)
        let roomID = try #require(store.activeRoomID)
        let action = await controller.refreshAfterForeground(environment: env)
        #expect(action == .none)
        #expect(recorded.value.count == 1)
        let first = try #require(recorded.value.first)
        #expect(first.contains("foreground backend=iroh outcome=sync-false"))
        #expect(!first.contains(roomID))
    }

    @Test @MainActor
    func syncFalseBudgetCapsAtThree() async throws {
        let recorded = record()
        defer { SentryCapture.resetForTesting() }
        let service = R50AP03RoomService()
        await service.setSyncResult(false)
        let (controller, _, env) = try makeController(service: service)
        for _ in 0..<5 {
            let action = await controller.refreshAfterForeground(environment: env)
            #expect(action == .none)
        }
        #expect(recorded.value.count == 3)
    }

    @Test @MainActor
    func startFailureDoesNotBurnSyncFalseBudget() async throws {
        let recorded = record()
        defer { SentryCapture.resetForTesting() }
        let service = R50AP03RoomService()
        await service.setStartError(.endpointUnavailable)
        await service.setSyncResult(false)
        let (controller, _, env) = try makeController(service: service)
        let action = await controller.refreshAfterForeground(environment: env)
        #expect(action == .none)
        #expect(!recorded.value.contains(where: { $0.contains("outcome=sync-false") }))
    }
}

extension R50AP03RoomService {
    func setStartError(_ error: R50AP03ServiceError?) { startError = error }
    func setSyncResult(_ value: Bool) { syncResult = value }
    func setSuspendStart(_ value: Bool) { suspendStart = value }
    func releaseStart() {
        for c in startContinuations { c.resume() }
        startContinuations.removeAll()
    }
}
